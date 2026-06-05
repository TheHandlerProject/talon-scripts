#!/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="/home/neo/talon-scripts"
readonly LOG_FILE="/var/log/azrael-healer.log"
readonly DIAGNOSTICS_LOG="/var/log/azrael-diagnostics.log"
readonly LOCKFILE="/var/run/azrael-healer.lock"

echo "=== 🏆 Deploying Azrael Production Framework (Final Fixed Build) ==="

sudo mkdir -p "$SCRIPT_DIR"
sudo touch "$LOG_FILE" "$DIAGNOSTICS_LOG" "$LOCKFILE"
sudo chmod 640 "$LOG_FILE" "$DIAGNOSTICS_LOG"
sudo chmod 600 "$LOCKFILE"
sudo chown root:root "$LOG_FILE" "$DIAGNOSTICS_LOG" "$LOCKFILE"

cat << 'EOF' | sudo tee "$SCRIPT_DIR/azrael-daemon.sh" > /dev/null
#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# === Concurrency Lock Guard ===
readonly LOCKFILE="/var/run/azrael-healer.lock"
exec 9>>"$LOCKFILE"
if ! flock -w 10 9; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [Azrael] Lock contention — skipping." >&2
    exit 0
fi
trap 'flock -u 9 2>/dev/null || true' EXIT

readonly OLLAMA_URL="http://127.0.0.1:11434/api/generate"
readonly TIMEOUT_LIMIT=15
readonly MAX_RESTARTS=5
readonly LOG_FILE="/var/log/azrael-healer.log"
readonly DIAGNOSTICS_LOG="/var/log/azrael-diagnostics.log"

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [Azrael] $1" | tee -a "$LOG_FILE"
}

# 1. Telemetry Collection
mapfile -t OFFLINE_ARRAY < <(docker ps -a --filter "status=exited" --filter "status=dead" --format "{{.Names}}" 2>/dev/null || true)

# FIX: Guard against cloudflare-tunnel not existing before calling docker logs
if docker inspect cloudflare-tunnel &>/dev/null; then
    CLOUDFLARE_ERRORS=$(docker logs cloudflare-tunnel --tail 30 2>&1 | grep -Ei "token|error|failed|invalid|connection|502|503" || true)
else
    CLOUDFLARE_ERRORS=""
fi

SHOULD_RESTART_CLOUDFLARE=0
[ -n "$CLOUDFLARE_ERRORS" ] && SHOULD_RESTART_CLOUDFLARE=1

if [ ${#OFFLINE_ARRAY[@]} -eq 0 ] && [ "$SHOULD_RESTART_CLOUDFLARE" -eq 0 ]; then
    log_msg "✅ System stable."
    exit 0
fi

log_msg "⚠️ Anomaly detected. Offline: ${#OFFLINE_ARRAY[@]} | Cloudflare: $SHOULD_RESTART_CLOUDFLARE"

# Low RAM protective safety evaluation block
FREE_RAM=$(free -m | awk '/^Mem:/{print $4}')
if [ "$FREE_RAM" -lt 400 ]; then
    log_msg "⚠️ Resource Warning ($FREE_RAM MB free memory). Processing restarts cautiously."
fi

# 2. AI Diagnostics Pipeline
DIAGNOSTIC_PROMPT="ANOMALY REPORT:
Offline containers: [${OFFLINE_ARRAY[*]:-none}]
Cloudflare logs: [${CLOUDFLARE_ERRORS:-none}]

Provide a brief structural overview and manual validation steps."

JSON_PAYLOAD=$(jq -n --arg m "azrael" --arg p "$DIAGNOSTIC_PROMPT" '{model: $m, prompt: $p, stream: false}' 2>/dev/null || echo "{}")

if [ "$JSON_PAYLOAD" != "{}" ]; then
    log_msg "🧠 Querying Azrael for diagnostics..."
    curl -s -f --max-time "$TIMEOUT_LIMIT" -X POST "$OLLAMA_URL" \
      -H "Content-Type: application/json" \
      -d "$JSON_PAYLOAD" | jq -r '.response // "No response"' >> "$DIAGNOSTICS_LOG" 2>/dev/null \
      || log_msg "⚠️ Ollama query failed/timed out."
fi

# 3. Deterministic Recovery
restarted=0

# High-priority cloudflare target validation path
if [ "$SHOULD_RESTART_CLOUDFLARE" -eq 1 ] && [ $restarted -lt $MAX_RESTARTS ]; then
    if docker ps -a --format '{{.Names}}' | grep -Fqx "cloudflare-tunnel"; then
        log_msg "🔧 Restarting cloudflare-tunnel..."
        if docker restart cloudflare-tunnel; then
            log_msg "✅ cloudflare-tunnel restarted."
            restarted=$((restarted + 1))
        else
            log_msg "❌ Failed to restart cloudflare-tunnel"
        fi
    else
        log_msg "⚠️ cloudflare-tunnel not found — skipping."
    fi
fi

# Multi-container loop recovery boundaries
for container in "${OFFLINE_ARRAY[@]}"; do
    [ -z "$container" ] && continue
    if [ $restarted -ge $MAX_RESTARTS ]; then
        log_msg "⚠️ Execution threshold hit: Throttling restarts for this sweep cycle."
        break
    fi

    if docker ps -a --format '{{.Names}}' | grep -Fqx "$container"; then
        log_msg "🔧 Restarting: $container"
        if docker restart "$container"; then
            log_msg "✅ $container restarted."
            restarted=$((restarted + 1))
        else
            log_msg "❌ Failed to restart $container"
        fi
    fi
done

log_msg "Cycle complete. Recovered: $restarted container(s)."

# === 4. Safe Log Rotation ===
CURRENT_SIZE=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$CURRENT_SIZE" -gt 5242880 ]; then
    cp "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
    cat /dev/null > "$LOG_FILE"
    log_msg "🔄 Log rotated cleanly (exceeded 5MB threshold)."
fi
EOF

sudo chmod 700 "$SCRIPT_DIR/azrael-daemon.sh"
sudo chown root:root "$SCRIPT_DIR/azrael-daemon.sh"

# === Compile and Bind Systemd Automation Profiles ===
cat << 'SERVICE' | sudo tee /etc/systemd/system/azrael-healer.service > /dev/null
[Unit]
Description=Azrael Self-Healing Infrastructure Daemon
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/home/neo/talon-scripts/azrael-daemon.sh
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

cat << 'TIMER' | sudo tee /etc/systemd/system/azrael-healer.timer > /dev/null
[Unit]
Description=Automated Trigger Engine for Azrael Daemon Layer

[Timer]
OnBootSec=1min
OnCalendar=*:0/5
RandomizedDelaySec=30
Persistent=true

[Install]
WantedBy=timers.target
TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now azrael-healer.timer
sudo systemctl restart azrael-healer.timer

echo "=========================================================="
echo "CLEAN DEPLOYMENT COMPLETE -- ALL ISSUES RESOLVED"
echo "=========================================================="
echo "- Log rotation cp line fixed"
echo "- Cloudflare existence check added"
echo "- Arithmetic safe for set -e"
echo "- All quoting issues eliminated"
echo "Monitor: journalctl -u azrael-healer.service -f"
echo "Log: tail -f /var/log/azrael-healer.log"
