#!/bin/bash
# ═══════════════════════════════════════════════════════════
# KNOX BROWSER — Install on Talon
# Adds headless Chromium + web deploy capability to Knox
# Run from the knox-browser directory
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[XX]${NC} $1"; exit 1; }

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}  KNOX BROWSER — INSTALL               ${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

# Check Docker
command -v docker &>/dev/null || fail "Docker not found — install Docker first"

# Build container
info "Building knox-browser container (first build takes ~3min)..."
docker build -t knox-browser . || fail "Docker build failed"
ok "Container built"

# Start service
info "Starting knox-browser..."
docker rm -f knox-browser 2>/dev/null
docker run -d \
  --name knox-browser \
  --restart unless-stopped \
  -p 127.0.0.1:8767:8767 \
  --shm-size=1gb \
  --security-opt seccomp:unconfined \
  -v /home/neo/.knox-vault:/home/neo/.knox-vault \
  -v /home/neo/knox-logs:/home/neo/knox-logs \
  -v /var/www/html:/var/www/html \
  knox-browser || fail "Container start failed"

# Wait for health
info "Waiting for knox-browser to be ready..."
for i in $(seq 1 15); do
  if curl -sf http://localhost:8767/health &>/dev/null; then
    ok "knox-browser is up"
    break
  fi
  sleep 2
  [ $i -eq 15 ] && fail "knox-browser didn't start in time — check: docker logs knox-browser"
done

# Store GitHub PAT if provided
if [ -n "$GITHUB_PAT" ]; then
  info "Storing GitHub PAT in vault..."
  curl -sf -X POST http://localhost:8767/vault \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"github_pat\",\"value\":\"$GITHUB_PAT\"}" && ok "GitHub PAT stored"
else
  warn "GITHUB_PAT not set — store it once with:"
  warn "  curl -X POST http://localhost:8767/vault -H 'Content-Type: application/json' -d '{\"name\":\"github_pat\",\"value\":\"ghp_YOUR_TOKEN\"}'"
fi

# Update Knox Modelfile
info "Rebuilding Knox with browser API knowledge..."
ollama create knox -f ./knox-modelfile && ok "Knox rebuilt" || warn "Knox rebuild failed — run manually: ollama create knox -f ./knox-modelfile"

# Add to systemd via docker (already handled by --restart unless-stopped)
ok "knox-browser will auto-restart on reboot via Docker"

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  KNOX BROWSER READY${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"
echo -e "API:     ${CYAN}http://localhost:8767${NC}"
echo -e "Health:  ${CYAN}http://localhost:8767/health${NC}"
echo -e "Queue:   ${CYAN}http://localhost:8767/queue${NC}"
echo ""
echo -e "Knox can now: browse, test pages, deploy to webroot + GitHub"
echo -e "Security changes still queue for your approval"
echo ""
echo -e "Tell Knox: ${YELLOW}Set up DuckDNS for Talonnet${NC}"
echo -e "He'll handle it. Comcast port forward will queue for you."
echo -e "\nMay the Schwartz be with you. — Knox"
