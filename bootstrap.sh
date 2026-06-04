#!/bin/bash
# ═══════════════════════════════════════════════════════════
# TALONNET BOOTSTRAP — run this once on a fresh Talon
# curl -sf https://raw.githubusercontent.com/TheHandlerProject/talon-scripts/main/bootstrap.sh | bash
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[XX]${NC} $1"; exit 1; }

GITHUB_RAW="https://raw.githubusercontent.com/TheHandlerProject/talon-scripts/main"
CONTEXT_DIR="/home/neo/knox-context"

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}  TALONNET BOOTSTRAP — SCHWARTZ NETWORK ${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

mkdir -p "$CONTEXT_DIR"

info "Pulling latest files from GitHub..."
for f in deploy-talon.sh talon-drop.html knox-modelfile; do
  curl -sf "$GITHUB_RAW/$f" -o "$CONTEXT_DIR/$f" \
    && ok "$f" \
    || fail "Could not fetch $f — check repo is public and file exists"
done

info "Deploying talon-drop.html to web root..."
sudo mkdir -p /var/www/html
sudo cp "$CONTEXT_DIR/talon-drop.html" /var/www/html/talon.html
ok "talon.html live"

info "Running deploy-talon.sh..."
bash "$CONTEXT_DIR/deploy-talon.sh" || fail "deploy-talon.sh failed"

info "Building Knox model..."
ollama create knox -f "$CONTEXT_DIR/knox-modelfile" \
  && ok "Knox model built" \
  || fail "Knox model build failed"

md5sum "$CONTEXT_DIR/knox-modelfile" | cut -d' ' -f1 > "$CONTEXT_DIR/.knox-modelfile-hash"

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  BOOTSTRAP COMPLETE${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"
echo -e "TALON UI:     ${CYAN}http://100.114.75.23${NC}"
echo -e "OPENWEBUI:    ${CYAN}http://100.114.75.23:3000${NC}"
echo -e "PUBLIC PANEL: ${CYAN}http://100.114.75.23:8888${NC}"
echo ""
echo -e "Future updates: ${YELLOW}knox-pull${NC}"
echo -e "May the Schwartz be with you. — Knox"
