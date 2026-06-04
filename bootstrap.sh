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
BROWSER_DIR="/home/neo/knox-browser"

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}  TALONNET BOOTSTRAP — SCHWARTZ NETWORK ${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

mkdir -p "$CONTEXT_DIR" "$BROWSER_DIR"

# 1. Pull core files
info "Pulling core files from GitHub..."
for f in deploy-talon.sh talon-drop.html knox-modelfile knox-context-patch.sh; do
  curl -sf "$GITHUB_RAW/$f" -o "$CONTEXT_DIR/$f" \
    && ok "$f" \
    || fail "Could not fetch $f"
done

# 2. Pull knox-browser files
info "Pulling knox-browser files..."
for f in Dockerfile requirements.txt knox-browser.py install.sh docker-compose.yml; do
  curl -sf "$GITHUB_RAW/$f" -o "$BROWSER_DIR/$f" \
    && ok "$f" \
    || fail "Could not fetch $f"
done

# 3. Deploy talon-drop.html
info "Deploying talon-drop.html..."
sudo mkdir -p /var/www/html
sudo cp "$CONTEXT_DIR/talon-drop.html" /var/www/html/talon.html
ok "talon.html live"

# 4. Run deploy script
info "Running deploy-talon.sh..."
bash "$CONTEXT_DIR/deploy-talon.sh" || fail "deploy-talon.sh failed"

# 5. Apply claude-context patch to knox-optimize.sh
info "Applying claude-context patch..."
bash "$CONTEXT_DIR/knox-context-patch.sh" && ok "claude-context patch applied" || warn "Context patch failed — run manually: bash $CONTEXT_DIR/knox-context-patch.sh"

# 6. Build Knox with browser API modelfile
info "Building Knox model..."
ollama create knox -f "$CONTEXT_DIR/knox-modelfile" \
  && ok "Knox model built" \
  || fail "Knox model build failed"

md5sum "$CONTEXT_DIR/knox-modelfile" | cut -d' ' -f1 > "$CONTEXT_DIR/.knox-modelfile-hash"

# 7. Install knox-browser
info "Installing knox-browser..."
cd "$BROWSER_DIR"
if [ -n "$GITHUB_PAT" ]; then
  GITHUB_PAT="$GITHUB_PAT" bash install.sh
else
  bash install.sh
  warn "No GITHUB_PAT set — store it after install:"
  warn "  curl -X POST http://localhost:8767/vault -H 'Content-Type: application/json' -d '{\"name\":\"github_pat\",\"value\":\"ghp_YOUR_TOKEN\"}'"
fi

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  BOOTSTRAP COMPLETE${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"
echo -e "TALON UI:     ${CYAN}http://100.114.75.23${NC}"
echo -e "OPENWEBUI:    ${CYAN}http://100.114.75.23:3000${NC}"
echo -e "PUBLIC PANEL: ${CYAN}http://100.114.75.23:8888${NC}"
echo -e "KNOX BROWSER: ${CYAN}http://localhost:8767${NC}"
echo ""
echo -e "Future updates: ${YELLOW}knox-pull${NC}"
echo -e "May the Schwartz be with you. — Knox"
