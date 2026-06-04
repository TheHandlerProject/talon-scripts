#!/bin/bash
# ═══════════════════════════════════════════════════════════
# KNOX CONTEXT PATCH
# Appends claude-context.txt generation to knox-optimize.sh
# Run once on Talon as neo: bash knox-context-patch.sh
# ═══════════════════════════════════════════════════════════

OPTIMIZE="/usr/local/bin/knox-optimize.sh"
CONTEXT_FILE="/home/neo/knox-logs/claude-context.txt"

echo "[..] Patching $OPTIMIZE with claude-context.txt generation..."

# Check target exists
if [ ! -f "$OPTIMIZE" ]; then
  echo "[XX] $OPTIMIZE not found — run deploy-talon.sh first"
  exit 1
fi

# Append context block if not already patched
if grep -q "claude-context" "$OPTIMIZE"; then
  echo "[OK] Already patched — nothing to do"
  exit 0
fi

sudo tee -a "$OPTIMIZE" > /dev/null << 'CONTEXTEOF'

# ── CLAUDE CONTEXT SNAPSHOT ──────────────────────────────────────────────────
# Writes /home/neo/knox-logs/claude-context.txt
# Drop this file into Claude at the start of any session to skip catch-up
CONTEXT_FILE="/home/neo/knox-logs/claude-context.txt"

{
echo "=== TALONNET CLAUDE CONTEXT — $(date '+%Y-%m-%d %H:%M') ==="
echo ""

echo "── NETWORK NODES ──"
echo "Talon (Rocinante):      100.114.75.23   Ubuntu 26.04   Ryzen 7 3700U   9.2GB RAM"
echo "Wonderwoman (Nebuchadnezzar): 100.109.52.96  Win10  i7-9750H  GTX1650"
echo "Router (Millennium Falcon):   Archer A7  OpenWrt  extroot pending"
echo "Comcast gateway:        10.0.0.1"
echo ""

echo "── TALON DOCKER SERVICES ──"
docker ps --format "{{.Names}}: {{.Status}} (ports: {{.Ports}})" 2>/dev/null || echo "Docker unreachable"
echo ""

echo "── OLLAMA MODELS LOADED ──"
curl -sf http://localhost:11434/api/tags \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('models',[]):
    print(f\"  {m['name']} ({round(m.get('size',0)/1e9,1)}GB)\")
" 2>/dev/null || echo "Ollama unreachable"
echo ""

echo "── WONDERWOMAN OLLAMA ──"
WW_IP="100.109.52.96"
curl -sf --max-time 5 "http://$WW_IP:11434/api/tags" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('models',[]):
    print(f\"  {m['name']}\")
" 2>/dev/null || echo "Wonderwoman Ollama unreachable or idle"
echo ""

echo "── SYSTEM HEALTH ──"
echo "Uptime:    $(uptime -p)"
echo "Load:      $(cat /proc/loadavg | cut -d' ' -f1-3)"
echo "RAM:       $(free -h | awk '/^Mem/{print $3"/"$2}')"
echo "Disk /:    $(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used)"}')"
echo ""

echo "── NETWORK STATUS ──"
ping -c1 -W2 8.8.8.8 &>/dev/null && echo "Internet:       OK" || echo "Internet:       FAIL"
ping -c1 -W2 10.0.0.1 &>/dev/null && echo "Comcast GW:     OK" || echo "Comcast GW:     FAIL"
ping -c1 -W2 100.109.52.96 &>/dev/null && echo "Wonderwoman:    OK" || echo "Wonderwoman:    OFFLINE"
echo ""

echo "── KNOX BROWSER SERVICE ──"
curl -sf --max-time 3 http://localhost:8767/health 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"  Status: {d.get('status')} v{d.get('version')}\")" \
  2>/dev/null || echo "  knox-browser: DOWN"
echo ""

echo "── VAULT KEYS ──"
curl -sf --max-time 3 http://localhost:8767/vault/keys 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f\"  {k}\") for k in d.get('keys',[])]" \
  2>/dev/null || echo "  vault unreachable"
echo ""

echo "── PENDING ACTION QUEUE ──"
curl -sf --max-time 3 http://localhost:8767/queue 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
actions=[a for a in d.get('actions',[]) if a.get('status')=='pending']
if actions:
    for a in actions:
        print(f\"  [{a['id']}] {a['type']}: {a['description']}\")
else:
    print('  No pending actions')
" 2>/dev/null || echo "  queue unreachable"
echo ""

echo "── SERVICES (systemd) ──"
for svc in knox-briefing lonestarr-panel; do
  STATUS=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
  echo "  $svc: $STATUS"
done
echo ""

echo "── LAST KNOX-PULL ──"
cat /home/neo/knox-context/.last-sync 2>/dev/null || echo "  Never synced"
echo ""

echo "── KNOWN PENDING TASKS (from deploy config) ──"
echo "  1. Router extroot (A7)"
echo "  2. Reyes SSH cert"
echo "  3. Fix thehandlerproject.github.io"
echo "  4. Port forward 8888 + DuckDNS DDNS"
echo "  5. Wonderwoman firewall — open port 11434"
echo "  6. Store GitHub PAT in knox-browser vault"
echo ""

echo "── GITHUB REPO ──"
echo "  https://github.com/TheHandlerProject/talon-scripts"
echo ""

echo "=== END CONTEXT ==="
} > "$CONTEXT_FILE"

echo "Claude context written: $CONTEXT_FILE"
CONTEXTEOF

sudo chmod +x "$OPTIMIZE"
echo "[OK] Patch applied — $OPTIMIZE will now write $CONTEXT_FILE at 1AM"
echo ""
echo "To generate context RIGHT NOW run:"
echo "  sudo /usr/local/bin/knox-optimize.sh"
echo "Or just the context block:"
echo "  grep -A200 'CLAUDE CONTEXT SNAPSHOT' /usr/local/bin/knox-optimize.sh | bash"
