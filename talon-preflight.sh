#!/bin/bash
# talon-preflight — verify Talon is ready before any major operation
# Checks: disk, RAM, Docker, Ollama, UFW, port conflicts, GitHub reachable
# Exit 0 = all clear. Exit 1 = issues found.

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; WARNINGS=$((WARNINGS+1)); }
fail() { echo -e "${RED}[XX]${NC} $1"; FAILURES=$((FAILURES+1)); }

WARNINGS=0
FAILURES=0

echo "=== Talon Pre-flight Check $(date '+%H:%M:%S') ==="

# 1. Disk space
DISK=$(df / | awk 'NR==2{print $5}' | tr -d '%')
[ "$DISK" -lt 80 ] && ok "Disk: ${DISK}% used" || warn "Disk: ${DISK}% used — consider cleanup"

# 2. RAM
RAM=$(free -m | awk '/^Mem/{print $7}')
[ "$RAM" -gt 512 ] && ok "RAM: ${RAM}MB free" || warn "RAM low: ${RAM}MB free"

# 3. Docker
docker ps &>/dev/null && ok "Docker: running" || fail "Docker: not running"

# 4. Ollama
curl -sf --max-time 5 http://localhost:11434/api/tags &>/dev/null \
  && ok "Ollama: responding" || fail "Ollama: not responding"

# 5. UFW active
UFW=$(sudo ufw status 2>/dev/null | head -1)
echo "$UFW" | grep -q "active" && ok "UFW: active" || fail "UFW: INACTIVE — harden before opening ports"

# 6. Port conflicts — check known services
declare -A EXPECTED_PORTS=(
  [3000]="open-webui"
  [11434]="ollama"
  [1880]="nodered"
  [8123]="homeassistant"
  [1883]="mosquitto"
  [8767]="knox-browser"
  [8888]="lonestarr"
)
for port in "${!EXPECTED_PORTS[@]}"; do
  service="${EXPECTED_PORTS[$port]}"
  LISTENING=$(ss -tlnp 2>/dev/null | grep ":${port} ")
  if [ -n "$LISTENING" ]; then
    ok "Port $port ($service): listening"
  else
    warn "Port $port ($service): NOT listening"
  fi
done

# 7. GitHub reachable
curl -sf --max-time 5 https://raw.githubusercontent.com/TheHandlerProject/talon-scripts/main/knox-modelfile-v3 \
  | grep -q "FROM mistral" \
  && ok "GitHub: reachable and serving files" \
  || warn "GitHub: unreachable or files not found"

# 8. Knox model exists
ollama list 2>/dev/null | grep -q "knox" \
  && ok "Knox model: loaded" \
  || fail "Knox model: missing — run: ollama create knox -f /home/neo/knox-context/knox-modelfile"

# 9. Internet
ping -c1 -W3 8.8.8.8 &>/dev/null && ok "Internet: OK" || fail "Internet: FAIL"

# 10. Tailscale
tailscale status &>/dev/null && ok "Tailscale: connected" || warn "Tailscale: not connected"

# Summary
echo ""
echo "=== Pre-flight Summary ==="
echo "Failures:  $FAILURES"
echo "Warnings:  $WARNINGS"
if [ $FAILURES -gt 0 ]; then
  echo -e "${RED}FAIL — Fix failures before proceeding${NC}"
  exit 1
elif [ $WARNINGS -gt 0 ]; then
  echo -e "${YELLOW}PASS WITH WARNINGS — Review warnings${NC}"
  exit 0
else
  echo -e "${GREEN}ALL CLEAR — Safe to proceed${NC}"
  exit 0
fi
