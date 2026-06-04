#!/bin/bash
# talon-doctor — autonomous self-healing watchdog
# Runs every 5 minutes via systemd timer
# Checks services three ways before acting. Verifies repairs. Logs everything.
# Evan never needs to touch this.

LOGFILE="/home/neo/knox-logs/talon-doctor.log"
ALERTFILE="/home/neo/knox-logs/talon-alerts.txt"
mkdir -p /home/neo/knox-logs

ts()     { date '+%Y-%m-%d %H:%M:%S'; }
log()    { echo "[$(ts)] $*" >> "$LOGFILE"; }
alert()  { echo "[$(ts)] ALERT: $*" | tee -a "$ALERTFILE" >> "$LOGFILE"; }
healed() { echo "[$(ts)] HEALED: $*" | tee -a "$ALERTFILE" >> "$LOGFILE"; }

# Rotate log at midnight — keep 14 days
TODAY=$(date +%Y-%m-%d)
LOGDATE=$(stat -c %y "$LOGFILE" 2>/dev/null | cut -d' ' -f1)
if [ -f "$LOGFILE" ] && [ "$LOGDATE" != "$TODAY" ]; then
  mv "$LOGFILE" "/home/neo/knox-logs/talon-doctor-${LOGDATE}.log"
  find /home/neo/knox-logs -name "talon-doctor-*.log" -mtime +14 -delete 2>/dev/null
fi

log "=== talon-doctor start ==="

# ── 1. CONTAINERS ──────────────────────────────────────────────────────────
REQUIRED=(open-webui nodered homeassistant mosquitto piper motioneye knox-browser frigate whisper comfyui)

for c in "${REQUIRED[@]}"; do
  # Check three ways
  STATUS_INSPECT=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null)
  STATUS_PS=$(docker ps --filter "name=^${c}$" --format '{{.Status}}' 2>/dev/null)
  RUNNING=$(docker ps -q --filter "name=^${c}$" 2>/dev/null)

  if [ -z "$RUNNING" ]; then
    alert "$c is down (inspect=$STATUS_INSPECT ps=$STATUS_PS)"
    docker start "$c" >> "$LOGFILE" 2>&1
    sleep 4
    # Verify repair
    VERIFY=$(docker ps -q --filter "name=^${c}$" 2>/dev/null)
    if [ -n "$VERIFY" ]; then
      healed "$c restarted and verified running"
    else
      alert "$c FAILED to restart — needs manual attention"
    fi
  else
    log "$c: running"
  fi
done

# ── 2. OLLAMA ──────────────────────────────────────────────────────────────
# Check three ways: API response, systemctl status, process check
OLLAMA_API=$(curl -sf --max-time 5 http://localhost:11434/api/tags 2>/dev/null)
OLLAMA_SVC=$(systemctl is-active ollama 2>/dev/null)
OLLAMA_PROC=$(pgrep -x ollama 2>/dev/null)

if [ -z "$OLLAMA_API" ] && [ -z "$OLLAMA_PROC" ]; then
  alert "Ollama down (api=no response, svc=$OLLAMA_SVC, proc=none)"
  sudo systemctl restart ollama >> "$LOGFILE" 2>&1
  sleep 6
  VERIFY=$(curl -sf --max-time 5 http://localhost:11434/api/tags 2>/dev/null)
  if [ -n "$VERIFY" ]; then
    healed "Ollama restarted and verified via API"
  else
    alert "Ollama FAILED to restart"
  fi
else
  log "Ollama: OK"
fi

# ── 3. KNOX BROWSER API ────────────────────────────────────────────────────
KB_HEALTH=$(curl -sf --max-time 3 http://localhost:8767/health 2>/dev/null)
KB_CONTAINER=$(docker ps -q --filter "name=^knox-browser$" 2>/dev/null)

if [ -z "$KB_HEALTH" ] || [ -z "$KB_CONTAINER" ]; then
  alert "Knox Browser down"
  docker restart knox-browser >> "$LOGFILE" 2>&1
  sleep 5
  VERIFY=$(curl -sf --max-time 3 http://localhost:8767/health 2>/dev/null)
  [ -n "$VERIFY" ] && healed "Knox Browser restarted" || alert "Knox Browser FAILED restart"
else
  log "Knox Browser: OK"
fi

# ── 4. KNOX BRIEFING SERVICE ───────────────────────────────────────────────
if ! systemctl is-active --quiet knox-briefing; then
  alert "knox-briefing service down"
  sudo systemctl restart knox-briefing >> "$LOGFILE" 2>&1
  sleep 2
  systemctl is-active --quiet knox-briefing \
    && healed "knox-briefing restarted" \
    || alert "knox-briefing FAILED restart"
else
  log "knox-briefing: OK"
fi

# ── 5. DISK ────────────────────────────────────────────────────────────────
DISK_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
log "Disk: ${DISK_PCT}% used"
if [ "$DISK_PCT" -gt 85 ]; then
  alert "Disk at ${DISK_PCT}% — running Docker prune"
  docker system prune -f >> "$LOGFILE" 2>&1
  DISK_AFTER=$(df / | awk 'NR==2{print $5}' | tr -d '%')
  log "Disk after prune: ${DISK_AFTER}%"
fi

# ── 6. RAM ─────────────────────────────────────────────────────────────────
RAM_FREE=$(free -m | awk '/^Mem/{print $7}')
log "RAM available: ${RAM_FREE}MB"
if [ "$RAM_FREE" -lt 300 ]; then
  alert "RAM critically low (${RAM_FREE}MB) — dropping caches"
  sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >> "$LOGFILE" 2>&1
  RAM_AFTER=$(free -m | awk '/^Mem/{print $7}')
  log "RAM after cache drop: ${RAM_AFTER}MB"
fi

# ── 7. INTERNET ────────────────────────────────────────────────────────────
if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
  # Try two more ways before alerting
  if ! ping -c1 -W3 1.1.1.1 &>/dev/null && ! curl -sf --max-time 5 https://google.com &>/dev/null; then
    alert "Internet unreachable — three checks failed"
  fi
else
  log "Internet: OK"
fi

# ── 8. TAILSCALE ───────────────────────────────────────────────────────────
TS_STATUS=$(tailscale status 2>/dev/null)
TS_SVC=$(systemctl is-active tailscaled 2>/dev/null)
if [ -z "$TS_STATUS" ] || [ "$TS_SVC" != "active" ]; then
  alert "Tailscale down (svc=$TS_SVC)"
  sudo systemctl restart tailscaled >> "$LOGFILE" 2>&1
  sleep 3
  tailscale status &>/dev/null \
    && healed "Tailscale reconnected" \
    || alert "Tailscale FAILED to reconnect"
else
  log "Tailscale: OK"
fi

log "=== talon-doctor complete ==="
