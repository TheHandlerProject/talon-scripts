#!/bin/bash
# talon-autonomy.sh — full autonomous setup
# Installs Knox v3, talon-doctor watchdog, morning briefing fix,
# knox-ask, knox-report commands, DuckDNS (if token provided)
# Run: bash talon-autonomy.sh
# With DuckDNS: DUCKDNS_DOMAIN=talonnet DUCKDNS_TOKEN=xxx bash talon-autonomy.sh

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[XX]${NC} $1"; exit 1; }

GITHUB_RAW="https://raw.githubusercontent.com/TheHandlerProject/talon-scripts/main"

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}  TALON AUTONOMY SETUP                 ${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

# ── 1. KNOX v3 MODEL ─────────────────────────────────────────────────────
info "Building Knox v3..."
curl -sf "$GITHUB_RAW/knox-modelfile-v3" -o /tmp/knox-modelfile-v3 \
  || fail "Could not fetch knox-modelfile-v3 from GitHub"
ollama create knox -f /tmp/knox-modelfile-v3 \
  && ok "Knox v3 built" \
  || fail "Knox v3 build failed"
cp /tmp/knox-modelfile-v3 /home/neo/knox-context/knox-modelfile
ok "Knox modelfile saved to context"

# ── 2. TALON-DOCTOR WATCHDOG ─────────────────────────────────────────────
info "Installing talon-doctor..."
curl -sf "$GITHUB_RAW/talon-doctor.sh" -o /usr/local/bin/talon-doctor \
  || fail "Could not fetch talon-doctor.sh"
sudo chmod +x /usr/local/bin/talon-doctor

sudo tee /etc/systemd/system/talon-doctor.service > /dev/null << 'SVCEOF'
[Unit]
Description=Talon Doctor Self-Healing Watchdog
After=docker.service network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/talon-doctor
SVCEOF

sudo tee /etc/systemd/system/talon-doctor.timer > /dev/null << 'TIMEREOF'
[Unit]
Description=Run Talon Doctor every 5 minutes
Requires=talon-doctor.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

sudo systemctl daemon-reload
sudo systemctl enable talon-doctor.timer
sudo systemctl start talon-doctor.timer
ok "talon-doctor installed and running every 5 minutes"

# ── 3. FIX KNOX-BRIEFING SERVICE ────────────────────────────────────────
info "Repairing knox-briefing service..."
sudo systemctl restart knox-briefing
sleep 2
systemctl is-active --quiet knox-briefing \
  && ok "knox-briefing running" \
  || warn "knox-briefing still failed — check: journalctl -u knox-briefing -n 20"

# ── 4. FIX 1AM CRON — ENSURE BRIEFING GENERATES ────────────────────────
info "Verifying 1AM cron jobs..."
# Remove duplicates and reset cleanly
crontab -l 2>/dev/null | grep -v -E "knox-optimize|knox-pull|knox-context" > /tmp/crontab-clean
echo "50 0 * * * /usr/local/bin/knox-pull" >> /tmp/crontab-clean
echo "0  1 * * * /usr/local/bin/knox-optimize.sh" >> /tmp/crontab-clean
echo "5  1 * * * bash /home/neo/knox-context/knox-context-now.sh" >> /tmp/crontab-clean
crontab /tmp/crontab-clean
rm /tmp/crontab-clean
ok "Cron jobs set: 12:50AM pull, 1AM optimize+briefing, 1:05AM context"

# ── 5. KNOX-ASK — query Knox from terminal ──────────────────────────────
info "Installing knox-ask..."
sudo tee /usr/local/bin/knox-ask > /dev/null << 'ASKEOF'
#!/bin/bash
# knox-ask — ask Knox anything from terminal with full context injected
# Usage: knox-ask "why is nodered down"
CONTEXT_FILE="/home/neo/knox-logs/claude-context.txt"
CONTEXT=$(cat "$CONTEXT_FILE" 2>/dev/null || echo "No context file found")
PROMPT="${*:-What needs attention on Talonnet right now?}"
ollama run knox "Current system state:
$CONTEXT

Question from Evan: $PROMPT"
ASKEOF
sudo chmod +x /usr/local/bin/knox-ask
ok "knox-ask installed"

# ── 6. KNOX-REPORT — pull morning briefing anytime ──────────────────────
info "Installing knox-report..."
sudo tee /usr/local/bin/knox-report > /dev/null << 'REPORTEOF'
#!/bin/bash
# knox-report — show morning briefing, or generate fresh if missing/stale
BRIEFING="/home/neo/knox-logs/morning-briefing.txt"
LOGFILE="/home/neo/knox-logs/$(date +%Y-%m-%d)-optimize.log"

if [ -f "$BRIEFING" ]; then
  # Check if briefing is from today
  BDATE=$(stat -c %y "$BRIEFING" 2>/dev/null | cut -d' ' -f1)
  TODAY=$(date +%Y-%m-%d)
  if [ "$BDATE" = "$TODAY" ]; then
    cat "$BRIEFING"
    exit 0
  fi
fi

echo "No briefing for today — generating now..."
SYSLOG=""
[ -f "$LOGFILE" ] && SYSLOG=$(cat "$LOGFILE")

# Build live snapshot
SNAPSHOT="Generated: $(date)
Uptime: $(uptime -p)
Load: $(cut -d' ' -f1-3 /proc/loadavg)
RAM: $(free -h | awk '/^Mem/{print $3"/"$2}')
Disk: $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')
Containers: $(docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null)
Ollama: $(curl -sf http://localhost:11434/api/tags | python3 -c "import sys,json; [print(m['name']) for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null)
Internet: $(ping -c1 -W2 8.8.8.8 &>/dev/null && echo OK || echo FAIL)
Wonderwoman: $(ping -c1 -W2 100.109.52.96 &>/dev/null && echo OK || echo OFFLINE)
$SYSLOG"

ollama run knox "Generate a morning briefing for Evan Schwartz. Be direct, no filler. Format:
1. NETWORK HEALTH
2. CONTAINER STATUS
3. SYSTEM HEALTH
4. OVERNIGHT OBSERVATIONS
5. RECOMMENDED ACTIONS (numbered)

System data:
$SNAPSHOT" | tee "$BRIEFING"
REPORTEOF
sudo chmod +x /usr/local/bin/knox-report
ok "knox-report installed — run anytime: knox-report"

# ── 7. DUCKDNS ───────────────────────────────────────────────────────────
if [ -n "$DUCKDNS_TOKEN" ] && [ -n "$DUCKDNS_DOMAIN" ]; then
  info "Installing DuckDNS for ${DUCKDNS_DOMAIN}.duckdns.org..."
  sudo mkdir -p /etc/duckdns
  sudo tee /etc/duckdns/duck.sh > /dev/null << DUCKEOF
#!/bin/bash
curl -sf "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" \
  -o /var/log/duckdns.log
DUCKEOF
  sudo chmod +x /etc/duckdns/duck.sh
  sudo bash /etc/duckdns/duck.sh
  crontab -l 2>/dev/null | grep -v duckdns > /tmp/ct; \
    echo "*/5 * * * * /etc/duckdns/duck.sh" >> /tmp/ct; crontab /tmp/ct; rm /tmp/ct
  ok "DuckDNS running for ${DUCKDNS_DOMAIN}.duckdns.org"
  # Queue port forward for Evan approval
  curl -sf -X POST http://localhost:8767/system-action \
    -H "Content-Type: application/json" \
    -d "{\"action_type\":\"port_forward\",\"description\":\"Forward port 8888 to Talon for DuckDNS public access\",\"command\":\"Log into 10.0.0.1 > Port Forwarding > TCP 8888 to 10.0.0.172:8888\"}" \
    > /dev/null 2>&1 && ok "Port forward queued for your approval"
else
  warn "DuckDNS skipped — run with: DUCKDNS_DOMAIN=talonnet DUCKDNS_TOKEN=yourtoken bash talon-autonomy.sh"
fi

# ── 8. RUN DOCTOR NOW ───────────────────────────────────────────────────
info "Running talon-doctor initial pass..."
sudo /usr/local/bin/talon-doctor
ok "Initial health check complete"

# ── 9. GENERATE FRESH CONTEXT ───────────────────────────────────────────
info "Generating fresh context file..."
bash /home/neo/knox-context/knox-context-now.sh && ok "Context updated"

# ── SUMMARY ─────────────────────────────────────────────────────────────
echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  AUTONOMY SETUP COMPLETE${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"
echo -e "${GREEN}✓${NC} Knox v3 — zero creativity, verify-three-ways, task-first"
echo -e "${GREEN}✓${NC} talon-doctor — heals every 5 minutes automatically"
echo -e "${GREEN}✓${NC} 1AM cron — briefing generates nightly"
echo -e "${GREEN}✓${NC} knox-ask  — terminal: knox-ask \"what's wrong\""
echo -e "${GREEN}✓${NC} knox-report — terminal: knox-report (get briefing anytime)"
[ -n "$DUCKDNS_TOKEN" ] && echo -e "${GREEN}✓${NC} DuckDNS live" || echo -e "${YELLOW}!${NC} DuckDNS needs token"
echo ""
echo -e "Morning report:  ${CYAN}knox-report${NC}"
echo -e "Ask Knox:        ${CYAN}knox-ask \"question\"${NC}"
echo -e "Doctor logs:     ${CYAN}tail -f /home/neo/knox-logs/talon-doctor.log${NC}"
echo -e "Alerts:          ${CYAN}cat /home/neo/knox-logs/talon-alerts.txt${NC}"
echo ""
echo -e "May the Schwartz be with you. — Knox"
