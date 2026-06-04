#!/bin/bash
# knox-context-now.sh — standalone, no dependencies
# Writes /home/neo/knox-logs/claude-context.txt immediately
# If optimize.sh exists, patches it. If not, installs itself as a cron.

CONTEXT_FILE="/home/neo/knox-logs/claude-context.txt"
OPTIMIZE="/usr/local/bin/knox-optimize.sh"
mkdir -p /home/neo/knox-logs

generate_context() {
{
echo "=== TALONNET CLAUDE CONTEXT — $(date '+%Y-%m-%d %H:%M') ==="
echo ""

echo "── NETWORK NODES ──"
echo "Talon:         100.114.75.23  Ubuntu 26.04  Ryzen 7 3700U  9.2GB RAM"
echo "Wonderwoman:   100.109.52.96  Win10  i7-9750H  GTX1650"
echo "Router:        Archer A7  OpenWrt  extroot pending"
echo "Comcast GW:    10.0.0.1"
echo ""

echo "── DOCKER CONTAINERS ──"
docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null || echo "Docker unreachable"
echo ""

echo "── OLLAMA MODELS (Talon) ──"
curl -sf --max-time 5 http://localhost:11434/api/tags \
  | python3 -c "
import sys,json
for m in json.load(sys.stdin).get('models',[]):
    print(f\"  {m['name']} ({round(m.get('size',0)/1e9,1)}GB)\")
" 2>/dev/null || echo "  Ollama unreachable"
echo ""

echo "── OLLAMA MODELS (Wonderwoman) ──"
curl -sf --max-time 5 http://100.109.52.96:11434/api/tags \
  | python3 -c "
import sys,json
for m in json.load(sys.stdin).get('models',[]):
    print(f\"  {m['name']}\")
" 2>/dev/null || echo "  Wonderwoman unreachable"
echo ""

echo "── SYSTEM HEALTH ──"
echo "Uptime: $(uptime -p)"
echo "Load:   $(cut -d' ' -f1-3 /proc/loadavg)"
echo "RAM:    $(free -h | awk '/^Mem/{print $3"/"$2}')"
echo "Disk:   $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
echo ""

echo "── NETWORK STATUS ──"
ping -c1 -W2 8.8.8.8      &>/dev/null && echo "Internet:    OK"   || echo "Internet:    FAIL"
ping -c1 -W2 10.0.0.1     &>/dev/null && echo "Comcast GW:  OK"   || echo "Comcast GW:  FAIL"
ping -c1 -W2 100.109.52.96 &>/dev/null && echo "Wonderwoman: OK"  || echo "Wonderwoman: OFFLINE"
echo ""

echo "── KNOX BROWSER ──"
curl -sf --max-time 3 http://localhost:8767/health \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"  {d.get('status')} v{d.get('version')}\")" \
  2>/dev/null || echo "  DOWN"
echo ""

echo "── VAULT KEYS ──"
curl -sf --max-time 3 http://localhost:8767/vault/keys \
  | python3 -c "import sys,json; [print(f'  {k}') for k in json.load(sys.stdin).get('keys',[])]" \
  2>/dev/null || echo "  vault unreachable"
echo ""

echo "── PENDING QUEUE ──"
curl -sf --max-time 3 http://localhost:8767/queue \
  | python3 -c "
import sys,json
actions=[a for a in json.load(sys.stdin).get('actions',[]) if a.get('status')=='pending']
[print(f\"  [{a['id']}] {a['type']}: {a['description']}\") for a in actions] if actions else print('  None')
" 2>/dev/null || echo "  unreachable"
echo ""

echo "── SERVICES ──"
for svc in knox-briefing lonestarr-panel docker; do
  echo "  $svc: $(systemctl is-active $svc 2>/dev/null || echo unknown)"
done
echo ""

echo "── LAST KNOX-PULL ──"
cat /home/neo/knox-context/.last-sync 2>/dev/null || echo "  Never"
echo ""

echo "── PENDING TASKS ──"
echo "  1. Router extroot (A7)"
echo "  2. Reyes SSH cert"
echo "  3. Fix thehandlerproject.github.io"
echo "  4. Port forward 8888 + DuckDNS DDNS"
echo "  5. Wonderwoman firewall — open port 11434"
echo "  6. GitHub PAT in vault: $(curl -sf --max-time 3 http://localhost:8767/vault/keys 2>/dev/null | python3 -c "import sys,json; print('STORED' if 'github_pat' in json.load(sys.stdin).get('keys',[]) else 'MISSING')" 2>/dev/null || echo unknown)"
echo ""

echo "── GITHUB ──"
echo "  https://github.com/TheHandlerProject/talon-scripts"
echo ""

echo "=== END CONTEXT ==="
} > "$CONTEXT_FILE"
}

# Generate now
generate_context
echo "[OK] Context written: $CONTEXT_FILE"

# Patch optimize.sh if it exists
if [ -f "$OPTIMIZE" ]; then
  if ! grep -q "claude-context" "$OPTIMIZE"; then
    echo "" | sudo tee -a "$OPTIMIZE" > /dev/null
    echo "# Auto-generate claude context" | sudo tee -a "$OPTIMIZE" > /dev/null
    echo "bash /home/neo/knox-context/knox-context-now.sh" | sudo tee -a "$OPTIMIZE" > /dev/null
    echo "[OK] Patched into knox-optimize.sh"
  else
    echo "[OK] knox-optimize.sh already has context generation"
  fi
fi

# Install cron if not present
if ! crontab -l 2>/dev/null | grep -q "knox-context-now"; then
  (crontab -l 2>/dev/null; echo "5 1 * * * bash /home/neo/knox-context/knox-context-now.sh") | crontab -
  echo "[OK] Cron installed — runs at 1:05AM daily"
fi

echo ""
echo "Drop this file into Claude to start any session:"
echo "  $CONTEXT_FILE"
