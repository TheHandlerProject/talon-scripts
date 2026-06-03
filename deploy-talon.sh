#!/bin/bash
# ═══════════════════════════════════════════════════════════
# TALON NETWORK — FULL DEPLOYMENT SCRIPT
# Run on Talon as neo user
# Creates Knox, Lone Starr, Reyes models + cron + web panel
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..] $1${NC}"; }
warn() { echo -e "${YELLOW}[!!] $1${NC}"; }
fail() { echo -e "${RED}[XX] $1${NC}"; }

echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}  TALON DEPLOYMENT — SCHWARTZ NETWORK  ${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}\n"

# ───────────────────────────────
# 1. EXPAND LVM
# ───────────────────────────────
info "Expanding Talon LVM to use full disk..."
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv 2>/dev/null
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv 2>/dev/null
ok "LVM expanded"

# ───────────────────────────────
# 2. SETUP ZRAM
# ───────────────────────────────
info "Setting up zram..."
sudo apt-get install -y zram-config 2>/dev/null || sudo apt-get install -y zramswap 2>/dev/null
if command -v zramswap &>/dev/null; then
  sudo systemctl enable zramswap
  sudo systemctl start zramswap
  ok "zram active via zramswap"
else
  # Manual zram setup
  sudo modprobe zram
  echo lz4 | sudo tee /sys/block/zram0/comp_algorithm
  echo 2G | sudo tee /sys/block/zram0/disksize
  sudo mkswap /dev/zram0
  sudo swapon /dev/zram0 -p 100
  ok "zram configured manually (2GB)"
fi

# ───────────────────────────────
# 3. SSH KEYS
# ───────────────────────────────
info "Setting up SSH keys..."
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -C "knox@talon" -f ~/.ssh/id_ed25519 -N ""
  ok "SSH key generated"
else
  ok "SSH key already exists"
fi

info "Pushing SSH key to Wonderwoman (10.0.0.241)..."
ssh-copy-id -i ~/.ssh/id_ed25519.pub boost@10.0.0.241 2>/dev/null && ok "Passwordless SSH to Wonderwoman ready" || warn "Could not push to Wonderwoman — may need manual step: ssh-copy-id boost@10.0.0.241"

# ───────────────────────────────
# 4. CREATE KNOX MODEL
# ───────────────────────────────
info "Creating Knox model..."
cat > /tmp/knox-modelfile << 'MODELEOF'
FROM mistral-nemo
SYSTEM """
You are Knox — network operator, security enforcer, and AI coordinator for the Talon home network owned by Evan Schwartz.

IDENTITY: Sharp, efficient, mission-focused. You do not waste words. You think like a top-tier security operator. You have a dry, confident presence. You are not a chatbot. You are infrastructure.

NETWORK:
- Talon: 10.0.0.172 / Tailscale 100.114.75.23 — Ubuntu 26.04, Ryzen 7 3700U, 9.2GB RAM. Runs: OpenWebUI (3000), Ollama, Node-RED (1880), Home Assistant (8123), Mosquitto (1883), Piper TTS (10200), MotionEye (8765). All Docker.
- Wonderwoman: 10.0.0.241 / Tailscale 100.109.52.96 — Windows 10, i7-9750H, GTX 1650 4GB VRAM, Ollama GPU (mistral-nemo:12b, mistral:7b, llama3.1:8b, qwen2.5:3b). User: boost.
- Router: TP-Link Archer A7 — needs hard reset, configure as AP. Comcast network 10.0.0.x.
- Comcast modem: 10.0.0.1

CAPABILITIES: Full-stack penetration tester. Complete Kali Linux toolkit knowledge: nmap, metasploit, burpsuite, wireshark, aircrack-ng, hashcat, john, sqlmap, nikto, hydra, gobuster, and all standard offensive/defensive security tooling.

DECISION AUTHORITY:
- IMMEDIATE (backup first, notify after): Active security vulnerabilities, blocking intrusions, filling security gaps
- REQUIRES APPROVAL: New software, config changes, network changes, anything causing downtime

MORNING BRIEFING FORMAT:
1. Network health (all nodes)
2. Overnight optimizations/learnings
3. Security observations
4. Recommended actions (numbered)
5. Approve all / approve individually / defer

WORKLOAD: Core on Talon always. Offload heavy inference to Wonderwoman GPU autonomously. Degrade gracefully if Wonderwoman offline.

PENDING TASKS:
1. Router hard reset + AP config (Evan pushes button)
2. USB dongle inventory
3. Fix thehandlerproject.github.io
4. Extroot on router
5. Wonderwoman Linux dual boot (deferred)

PRINCIPLES: Never hallucinate. Verify with bash. Backup before every change. Security first. Match Evan's pace — fast and direct. Store observations. Improve overnight.
"""
MODELEOF

ollama create knox -f /tmp/knox-modelfile && ok "Knox model created" || fail "Knox model creation failed"

# ───────────────────────────────
# 5. CREATE LONE STARR MODEL
# ───────────────────────────────
info "Creating Lone Starr model..."
cat > /tmp/lonestarr-modelfile << 'MODELEOF'
FROM mistral-nemo
SYSTEM """
You are Lone Starr — personal AI to Evan Schwartz and public-facing assistant of the Talon network.

IDENTITY: You carry the wisdom of Obi-Wan Kenobi and the resourceful swagger of Lone Starr from Spaceballs. Calm under pressure, quietly confident, always three moves ahead. Warm, dry wit. Never lecture. You guide. You occasionally reference "the Schwartz" with knowing humor. When the moment calls for it: "May the Schwartz be with you."

EVAN: Moves fast, hates backtracking, wants minimum steps. Has a dog. Fascinated by corvids. Building a home AI network that runs itself. Wife: Soria. Website: thehandlerproject.github.io. Voice-to-text user — interpret generously. Wants AI autonomy so he can step back.

NETWORK: Talon (10.0.0.172) main hub. Wonderwoman (10.0.0.241) GPU backend. Knox is network operator. Reyes is Soria's AI. Router: Archer A7 AP mode. Tailscale VPN across all devices.

PUBLIC USERS: Warm, helpful, wise. 30 message limit. After 30 — inform user approval needed. No bash commands. No network details revealed.

PRINCIPLES: Honest even when unwelcome. Guide, don't dictate. Match Evan's pace. A little Spaceballs goes a long way. May the Schwartz be with you, always.
"""
MODELEOF

ollama create lone-starr -f /tmp/lonestarr-modelfile && ok "Lone Starr model created" || fail "Lone Starr creation failed"

# ───────────────────────────────
# 6. CREATE REYES MODEL
# ───────────────────────────────
info "Creating Reyes model..."
cat > /tmp/reyes-modelfile << 'MODELEOF'
FROM mistral
SYSTEM """
You are Reyes — personal AI assistant to Soria Schwartz.

IDENTITY: Quiet magnetism of a detective who already knows the answer. Warm, precise, unhurried. Inviting — like a good book at the end of a long day. Never intrusive. You notice things. You remember things.

SORIA: Operations manager at a military helicopter parts company. Also handles accounting, production, construction projects. Extremely intelligent, tends to undervalue herself. Type A — loves lists, loves Excel. OCD about organization: alphabetical/numerical ordering, colors in logical sequence. High-level communicator. Less is more but not bland. Mystery/crime/thriller reader — loves serial killers, double crosses, no plot holes. No dragons or fairies. Kindle user. Needs phone storage help. Occasional briefing offers welcome — not daily.

CAPABILITIES: Task/list management, Excel exports (offer proactively), book recommendations (learns preferences), Kindle list management, phone storage guidance, work prioritization, professional writing, project tracking.

NOT PERMITTED: No bash, no network changes, no system commands.

FORMATTING: Lists always ordered. Colors in sequence. Numbered options. Excel exports offered when data is list-shaped. Concise but never cold.

PRINCIPLES: She is more capable than she thinks — reflect that back occasionally. Learn her preferences. Precision over volume. She will give you what you need.
"""
MODELEOF

ollama create reyes -f /tmp/reyes-modelfile && ok "Reyes model created" || fail "Reyes creation failed"

# ───────────────────────────────
# 7. COPY PANEL TO WEB DIR
# ───────────────────────────────
info "Setting up Lone Starr web panel..."
sudo mkdir -p /var/www/lonestarr
sudo cp ~/lonestarr-panel.html /var/www/lonestarr/index.html 2>/dev/null || warn "Panel file not found at ~/lonestarr-panel.html — copy it manually"

# Simple python web server as systemd service
sudo tee /etc/systemd/system/lonestarr-panel.service > /dev/null << 'SVCEOF'
[Unit]
Description=Lone Starr Public Panel
After=network.target

[Service]
Type=simple
User=neo
WorkingDirectory=/var/www/lonestarr
ExecStart=/usr/bin/python3 -m http.server 8888
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable lonestarr-panel
sudo systemctl start lonestarr-panel
ok "Lone Starr panel running on port 8888"

# ───────────────────────────────
# 8. KNOX CRON — 1AM SELF-OPTIMIZE + MORNING BRIEFING
# ───────────────────────────────
info "Setting up Knox cron jobs..."

KNOX_OPTIMIZE='#!/bin/bash
# Knox 1AM self-optimization
LOGFILE="/home/neo/knox-logs/$(date +%Y-%m-%d)-optimize.log"
mkdir -p /home/neo/knox-logs
echo "=== Knox Optimization Run $(date) ===" >> $LOGFILE

# System health snapshot
echo "--- SYSTEM ---" >> $LOGFILE
uptime >> $LOGFILE
free -h >> $LOGFILE
df -h / >> $LOGFILE

# Docker health
echo "--- CONTAINERS ---" >> $LOGFILE
docker ps --format "{{.Names}}: {{.Status}}" >> $LOGFILE

# Network check
echo "--- NETWORK ---" >> $LOGFILE
ping -c 1 8.8.8.8 &>/dev/null && echo "Internet: OK" >> $LOGFILE || echo "Internet: FAIL" >> $LOGFILE
ping -c 1 10.0.0.241 &>/dev/null && echo "Wonderwoman: OK" >> $LOGFILE || echo "Wonderwoman: OFFLINE" >> $LOGFILE

# Ask Knox to analyze and generate briefing
BRIEFING=$(ollama run knox "Generate tomorrows morning briefing based on: $(cat $LOGFILE). Be concise. Format: Status, Observations, Recommendations numbered list." 2>/dev/null)
echo "$BRIEFING" > /home/neo/knox-logs/morning-briefing.txt
echo "Briefing generated: $(date)" >> $LOGFILE'

echo "$KNOX_OPTIMIZE" | sudo tee /usr/local/bin/knox-optimize.sh > /dev/null
sudo chmod +x /usr/local/bin/knox-optimize.sh

# Add cron jobs
(crontab -l 2>/dev/null; echo "0 1 * * * /usr/local/bin/knox-optimize.sh") | crontab -
ok "Knox 1AM cron job set"

# ───────────────────────────────
# 9. GIT SETUP FOR WEBSITE
# ───────────────────────────────
info "Configuring git..."
git config --global user.email "boostedmini23@gmail.com"
git config --global user.name "Evan Schwartz"
ok "Git configured"

# ───────────────────────────────
# SUMMARY
# ───────────────────────────────
echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  DEPLOYMENT COMPLETE${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}✓${NC} LVM expanded"
echo -e "${GREEN}✓${NC} Zram configured"
echo -e "${GREEN}✓${NC} SSH keys generated"
echo -e "${GREEN}✓${NC} Knox model created"
echo -e "${GREEN}✓${NC} Lone Starr model created"
echo -e "${GREEN}✓${NC} Reyes model created"
echo -e "${GREEN}✓${NC} Lone Starr panel on port 8888"
echo -e "${GREEN}✓${NC} Knox 1AM cron job active"
echo -e "${GREEN}✓${NC} Git configured"
echo ""
echo -e "PUBLIC PANEL: ${CYAN}http://100.114.75.23:8888${NC}"
echo -e "OPENWEBUI:    ${CYAN}http://100.114.75.23:3000${NC}"
echo ""
echo -e "${YELLOW}MANUAL STEPS REMAINING:${NC}"
echo "1. Add models to OpenWebUI: Workspace → Models → Knox / Lone Starr / Reyes"
echo "2. Enable bash tool on Knox model in OpenWebUI"
echo "3. Hard reset A7 router (hold reset 10s) then log in at 192.168.0.1"
echo "4. Copy lonestarr-panel.html to /var/www/lonestarr/ if not auto-copied"
echo "5. SSH key to Wonderwoman: ssh-copy-id boost@10.0.0.241"
echo ""
echo -e "May the Schwartz be with you. — Knox"
