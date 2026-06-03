#!/bin/bash
# KNOX UPDATE & VERIFICATION SCRIPT
# Run on Talon — verifies everything from today and sets up web panels

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "${CYAN}[..] $1${NC}"; }

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}  KNOX VERIFICATION — JUNE 3 2026      ${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

# 1. LVM
info "Checking LVM..."
SIZE=$(df -h / | awk 'NR==2{print $2}')
echo "  Disk size: $SIZE"
[[ "$SIZE" == *"4"* ]] && ok "LVM expanded" || warn "LVM may not be fully expanded — current: $SIZE"

# 2. ZRAM
info "Checking zram..."
swapon --show | grep -q zram && ok "Zram active" || fail "Zram not found"

# 3. SSH TO WONDERWOMAN
info "Testing passwordless SSH to Wonderwoman..."
ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes -o ConnectTimeout=5 boost@100.109.52.96 echo "CONNECTED" 2>/dev/null && ok "Passwordless SSH to Wonderwoman working" || fail "SSH to Wonderwoman failed"

# 4. CRON
info "Checking cron..."
crontab -l 2>/dev/null | grep -q knox && ok "Knox cron job active" || fail "Knox cron not found"

# 5. TIMEZONE
info "Checking timezone..."
TZ=$(timedatectl | grep "Time zone" | awk '{print $3}')
echo "  Timezone: $TZ"
[[ "$TZ" == *"Los_Angeles"* ]] && ok "Timezone set to Pacific" || warn "Timezone is $TZ — expected America/Los_Angeles"

# 6. OPENWEBUI TIMEOUT
info "Checking OpenWebUI timeout..."
docker inspect open-webui 2>/dev/null | grep -q "TIMEOUT" && ok "OpenWebUI timeout configured" || warn "Timeout env vars not found — may need to recheck"

# 7. LONE STARR PANEL
info "Checking Lone Starr panel on port 8888..."
curl -s -o /dev/null -w "%{http_code}" http://localhost:8888 | grep -q "200\|301\|302" && ok "Panel responding on port 8888" || fail "Panel not responding"

# 8. SET UP INDEX PAGE
info "Setting up panel index page..."
sudo tee /var/www/lonestarr/index.html > /dev/null << 'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>LONE STARR NETWORK</title>
<style>
  body { background:#060a0d; display:flex; flex-direction:column; align-items:center; justify-content:center; height:100vh; font-family:monospace; gap:20px; margin:0; }
  .title { color:#00d4ff; font-size:24px; letter-spacing:4px; margin-bottom:20px; text-shadow: 0 0 12px rgba(0,212,255,0.5); }
  a { color:#00d4ff; font-size:16px; padding:14px 32px; border:1px solid #00d4ff; text-decoration:none; letter-spacing:2px; transition:all 0.2s; }
  a:hover { background:rgba(0,212,255,0.1); box-shadow: 0 0 16px rgba(0,212,255,0.3); }
  .sub { color:#2a5a70; font-size:11px; letter-spacing:2px; margin-top:20px; }
</style>
</head>
<body>
  <div class="title">◈ LONE STARR NETWORK</div>
  <a href="/lonestarr-expanse.html">TACTICAL INTERFACE — PRIVATE</a>
  <a href="/lonestarr-public.html">PUBLIC ACCESS PANEL</a>
  <div class="sub">MAY THE SCHWARTZ BE WITH YOU</div>
</body>
</html>
HTMLEOF
ok "Index page created"

# 9. CHECK HTML FILES
info "Checking panel files..."
ls /var/www/lonestarr/ | grep -q "lonestarr-expanse" && ok "Private panel file exists" || warn "lonestarr-expanse.html missing — upload to /var/www/lonestarr/"
ls /var/www/lonestarr/ | grep -q "lonestarr-public" && ok "Public panel file exists" || warn "lonestarr-public.html missing — upload to /var/www/lonestarr/"

# 10. PULL FROM GITHUB IF MISSING
if ! ls /var/www/lonestarr/ | grep -q "lonestarr-expanse"; then
  info "Pulling lonestarr-expanse.html from GitHub..."
  curl -sO https://raw.githubusercontent.com/TheHandlerProject/talon-scripts/main/lonestarr-expanse.html 2>/dev/null && sudo mv lonestarr-expanse.html /var/www/lonestarr/ && ok "Private panel pulled from GitHub" || fail "Could not pull from GitHub — upload manually"
fi

if ! ls /var/www/lonestarr/ | grep -q "lonestarr-public"; then
  info "Pulling lonestarr-public.html from GitHub..."
  curl -sO https://raw.githubusercontent.com/TheHandlerProject/talon-scripts/main/lonestarr-public.html 2>/dev/null && sudo mv lonestarr-public.html /var/www/lonestarr/ && ok "Public panel pulled from GitHub" || fail "Could not pull from GitHub — upload manually"
fi

# 11. RESTART PANEL SERVICE
info "Restarting Lone Starr panel service..."
sudo systemctl restart lonestarr-panel && ok "Panel service restarted" || fail "Panel service restart failed"

# SUMMARY
echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  VERIFICATION COMPLETE${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo ""
echo -e "PRIVATE PANEL: ${CYAN}http://100.114.75.23:8888/lonestarr-expanse.html${NC}"
echo -e "PUBLIC PANEL:  ${CYAN}http://100.114.75.23:8888/lonestarr-public.html${NC}"
echo -e "INDEX:         ${CYAN}http://100.114.75.23:8888${NC}"
echo ""
echo -e "Files in /var/www/lonestarr/:"
ls -lh /var/www/lonestarr/
echo ""
echo -e "${YELLOW}Remember to upload both HTML files to GitHub talon-scripts repo${NC}"
echo -e "${GREEN}Knox standing by. May the Schwartz be with you.${NC}"
