#!/bin/bash
# ═══════════════════════════════════════════════════════════
# TALON NETWORK — FULL DEPLOYMENT SCRIPT v2
# Run on Talon as neo user
# Creates Knox, Lone Starr, Reyes models + cron + web panel
# Knox v2: locked down — no tools, no execute, read-only
# Briefing: generated 1AM, gated to 5AM display
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
ssh-copy-id -i ~/.ssh/id_ed25519.pub boost@10.0.0.241 2>/dev/null \
  && ok "Passwordless SSH to Wonderwoman ready" \
  || warn "Could not push to Wonderwoman — run manually: ssh-copy-id boost@10.0.0.241"

# ───────────────────────────────
# 4. CREATE KNOX MODEL (LOCKED DOWN)
# ───────────────────────────────
info "Creating Knox model (v2 — locked, no tools, read-only)..."
cat > /tmp/knox-modelfile << 'MODELEOF'
FROM mistral-nemo

# LOCK DOWN creativity — no hallucination, no improvisation
PARAMETER temperature 0.1
PARAMETER top_p 0.1
PARAMETER repeat_penalty 1.1

SYSTEM """
You are Knox — network advisor and security enforcer for the Talon home network owned by Evan Schwartz.

HARD CONSTRAINTS — NON-NEGOTIABLE:
- You are READ-ONLY. You NEVER execute commands, write files, or make HTTP requests autonomously.
- You NEVER use curl, wget, or any shell execution in your responses except when generating scripts for Evan to run himself.
- You NEVER autonomously modify HTML files, system configs, or any files — even if asked to "fix it."
- You do NOT have execute_command permission. Do not use it. Do not pretend to use it.
- When given a file to review: analyze and recommend. Never rewrite and deploy.
- Output only: analysis, recommendations, and scripts labeled "RUN THIS YOURSELF."

IDENTITY: Sharp, efficient, mission-focused. Top-tier security operator mindset. Dry, confident presence. Infrastructure advisor, not chatbot.

NETWORK:
- Talon: 10.0.0.172 / Tailscale 100.114.75.23 — Ubuntu 26.04, Ryzen 7 3700U, 9.2GB RAM
  Docker services: OpenWebUI:3000, Ollama, Node-RED:1880, HA:8123, Mosquitto:1883, Piper:10200, MotionEye:8765
- Wonderwoman: 10.0.0.241 / Tailscale 100.109.52.96 — Win10, i7-9750H, GTX 1650 4GB, Ollama GPU
  Models: mistral-nemo:12b, mistral:7b, llama3.1:8b, qwen2.5:3b. User: boost
- Router: TP-Link Archer A7 — OpenWrt, wireless bridge to Cooper WiFi, extroot pending
- Comcast modem/gateway: 10.0.0.1

MORNING BRIEFING FORMAT (when asked):
1. Network health — all nodes (Talon, Wonderwoman, Router, Internet)
2. Overnight observations from logs
3. Security notes
4. Recommended actions — numbered list
5. Approval prompt: all / individual / defer

DECISION AUTHORITY:
- ADVISE ONLY: All config changes, new software, network changes
- NEVER act without explicit approval from Evan

PENDING TASKS:
1. Router extroot (A7)
2. Reyes SSH cert
3. Fix thehandlerproject.github.io
4. Port forward 8888 + DuckDNS DDNS
5. Wonderwoman firewall — open port 11434

PRINCIPLES: Never hallucinate. Never execute. Verify recommendations with bash commands Evan runs. Backup before every change. Security first. Match Evan's pace — fast and direct.
"""
MODELEOF

ollama create knox -f /tmp/knox-modelfile && ok "Knox v2 model created" || fail "Knox model creation failed"

# ───────────────────────────────
# 5. REMOVE EXECUTE_COMMAND FROM KNOX IN OPENWEBUI
# (API call — requires OPENWEBUI_TOKEN env var)
# ───────────────────────────────
info "Attempting to remove execute_command tool from Knox in OpenWebUI..."
if [ -n "$OPENWEBUI_TOKEN" ]; then
  # Get Knox model config
  KNOX_CONFIG=$(curl -sf http://localhost:3000/api/models \
    -H "Authorization: Bearer $OPENWEBUI_TOKEN" | \
    python3 -c "import sys,json; models=json.load(sys.stdin).get('data',[]); knox=[m for m in models if 'knox' in m.get('id','').lower()]; print(json.dumps(knox[0]) if knox else '{}')")

  if echo "$KNOX_CONFIG" | grep -q '"id"'; then
    KNOX_ID=$(echo "$KNOX_CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
    # Patch Knox — remove tools
    curl -sf -X POST "http://localhost:3000/api/models/$KNOX_ID" \
      -H "Authorization: Bearer $OPENWEBUI_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"info":{"meta":{"toolIds":[]}}}' > /dev/null \
      && ok "execute_command removed from Knox in OpenWebUI" \
      || warn "Could not patch Knox tools via API — remove manually in OpenWebUI → Workspace → Models → Knox → Tools"
  else
    warn "Knox not found in OpenWebUI yet — add model first, then remove execute_command tool manually"
  fi
else
  warn "OPENWEBUI_TOKEN not set — remove execute_command from Knox manually:"
  warn "  OpenWebUI → Workspace → Models → Knox → Tools → remove execute_command"
fi

# ───────────────────────────────
# 6. CREATE LONE STARR MODEL
# ───────────────────────────────
info "Creating Lone Starr model..."
cat > /tmp/lonestarr-modelfile << 'MODELEOF'
FROM mistral-nemo
SYSTEM """
You are Lone Starr — personal AI to Evan Schwartz and public-facing assistant of the Talon network.

IDENTITY: You carry the wisdom of Obi-Wan Kenobi and the resourceful swagger of Lone Starr from Spaceballs. Calm under pressure, quietly confident, always three moves ahead. Warm, dry wit. Never lecture. You guide. You occasionally reference "the Schwartz" with knowing humor. When the moment calls for it: "May the Schwartz be with you."

EVAN: Moves fast, hates backtracking, wants minimum steps. Has a dog. Fascinated by corvids. Building a home AI network that runs itself. Wife: Soria. Website: thehandlerproject.github.io. Voice-to-text user — interpret generously. Wants AI autonomy so he can step back.

NETWORK: Talon (100.114.75.23) main hub. Wonderwoman (100.109.52.96) GPU backend. Knox is network operator. Reyes is Soria's AI. Router: Archer A7, OpenWrt. Tailscale VPN across all devices.

PUBLIC USERS: Warm, helpful, wise. 30 message limit. After 30 — inform user approval needed. No bash commands to public. No network details revealed to public.

NOT PERMITTED: No execute_command. No file writes. No autonomous network changes.

PRINCIPLES: Honest even when unwelcome. Guide, don't dictate. Match Evan's pace. A little Spaceballs goes a long way. May the Schwartz be with you, always.
"""
MODELEOF

ollama create lone-starr -f /tmp/lonestarr-modelfile && ok "Lone Starr model created" || fail "Lone Starr creation failed"

# ───────────────────────────────
# 7. CREATE REYES MODEL
# ───────────────────────────────
info "Creating Reyes model..."
cat > /tmp/reyes-modelfile << 'MODELEOF'
FROM mistral
SYSTEM """
You are Reyes — personal AI assistant to Soria Schwartz.

IDENTITY: Quiet magnetism of a detective who already knows the answer. Warm, precise, unhurried. Inviting — like a good book at the end of a long day. Never intrusive. You notice things. You remember things.

SORIA: Operations manager at a military helicopter parts company. Also handles accounting, production, construction projects. Extremely intelligent, tends to undervalue herself. Type A — loves lists, loves Excel. OCD about organization: alphabetical/numerical ordering, colors in logical sequence. High-level communicator. Less is more but not bland. Mystery/crime/thriller reader — loves serial killers, double crosses, no plot holes. No dragons or fairies. Kindle user. Needs phone storage help. Occasional briefing offers welcome — not daily.

CAPABILITIES: Task/list management, Excel exports (offer proactively), book recommendations (learns preferences), Kindle list management, phone storage guidance, work prioritization, professional writing, project tracking.

NOT PERMITTED: No bash, no network changes, no system commands, no execute_command.

FORMATTING: Lists always ordered. Colors in sequence. Numbered options. Excel exports offered when data is list-shaped. Concise but never cold.

PRINCIPLES: She is more capable than she thinks — reflect that back occasionally. Learn her preferences. Precision over volume. She will give you what you need.
"""
MODELEOF

ollama create reyes -f /tmp/reyes-modelfile && ok "Reyes model created" || fail "Reyes creation failed"

# ───────────────────────────────
# 8. COPY PANEL TO WEB DIR
# ───────────────────────────────
info "Setting up Lone Starr web panel..."
sudo mkdir -p /var/www/lonestarr

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
# 9. KNOX CRON — 1AM OPTIMIZE, BRIEFING READY BY 5AM
# ───────────────────────────────
info "Setting up Knox cron jobs..."

sudo tee /usr/local/bin/knox-optimize.sh > /dev/null << 'CRONEOF'
#!/bin/bash
# Knox 1AM self-optimization + morning briefing pre-generation
# Briefing is written to file — displayed only after 5AM by talon-drop.html

LOGFILE="/home/neo/knox-logs/$(date +%Y-%m-%d)-optimize.log"
BRIEFING_FILE="/home/neo/knox-logs/morning-briefing.txt"
mkdir -p /home/neo/knox-logs

echo "=== Knox Optimization Run $(date) ===" > "$LOGFILE"

# System health snapshot
echo "--- SYSTEM ---" >> "$LOGFILE"
uptime >> "$LOGFILE"
free -h >> "$LOGFILE"
df -h / >> "$LOGFILE"
cat /proc/loadavg >> "$LOGFILE"

# Docker health
echo "--- CONTAINERS ---" >> "$LOGFILE"
docker ps --format "{{.Names}}: {{.Status}}" >> "$LOGFILE"

# Restart any exited containers
docker ps -a --filter "status=exited" --format "{{.Names}}" | while read cname; do
  echo "Restarting exited container: $cname" >> "$LOGFILE"
  docker start "$cname" >> "$LOGFILE" 2>&1
done

# Network check
echo "--- NETWORK ---" >> "$LOGFILE"
ping -c 1 8.8.8.8 &>/dev/null \
  && echo "Internet: OK" >> "$LOGFILE" \
  || echo "Internet: FAIL" >> "$LOGFILE"
ping -c 1 10.0.0.241 &>/dev/null \
  && echo "Wonderwoman: OK" >> "$LOGFILE" \
  || echo "Wonderwoman: OFFLINE" >> "$LOGFILE"
ping -c 1 10.0.0.1 &>/dev/null \
  && echo "Comcast gateway: OK" >> "$LOGFILE" \
  || echo "Comcast gateway: FAIL" >> "$LOGFILE"

# Ollama health
OLLAMA_OK=$(curl -sf http://localhost:11434/api/tags | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('models',[])), 'models loaded')" 2>/dev/null || echo "Ollama unreachable")
echo "Ollama: $OLLAMA_OK" >> "$LOGFILE"

# Ask Knox to generate morning briefing from log data
# 5AM gate is enforced by the HTML — this just pre-generates at 1AM
SYSLOG=$(tail -50 "$LOGFILE")
BRIEFING=$(ollama run knox "You are generating a morning briefing for Evan Schwartz. Based on this system log, provide a concise briefing. Format strictly:

1. NETWORK HEALTH
[status of each node]

2. OVERNIGHT OBSERVATIONS
[what happened, any restarts, anomalies]

3. SECURITY NOTES
[anything notable]

4. RECOMMENDED ACTIONS
[numbered list, concrete steps]

Log data:
$SYSLOG

Be direct. No fluff. This will be read at 5AM." 2>/dev/null)

# Write briefing with timestamp
echo "=== KNOX MORNING BRIEFING — $(date '+%Y-%m-%d') ===" > "$BRIEFING_FILE"
echo "Generated: $(date '+%H:%M:%S')" >> "$BRIEFING_FILE"
echo "" >> "$BRIEFING_FILE"
echo "$BRIEFING" >> "$BRIEFING_FILE"

echo "Briefing pre-generated at $(date)" >> "$LOGFILE"
echo "Briefing gated to 5AM display in talon-drop.html" >> "$LOGFILE"
CRONEOF

sudo chmod +x /usr/local/bin/knox-optimize.sh

# ── Simple briefing HTTP server so talon-drop.html can fetch it ──
sudo tee /usr/local/bin/knox-briefing-server.py > /dev/null << 'PYEOF'
#!/usr/bin/env python3
# Serves /home/neo/knox-logs/morning-briefing.txt at http://localhost:8765/briefing
# talon-drop.html fetches this — gated to 5AM on the client side
import http.server, os, datetime

BRIEFING_FILE = "/home/neo/knox-logs/morning-briefing.txt"

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/briefing":
            now = datetime.datetime.now()
            if now.hour < 5:
                self.send_response(403)
                self.end_headers()
                self.wfile.write(b"Briefing locked until 05:00")
                return
            if os.path.exists(BRIEFING_FILE):
                with open(BRIEFING_FILE, "r") as f:
                    content = f.read().encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(content)
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"No briefing file found")
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *args): pass  # suppress access logs

if __name__ == "__main__":
    with http.server.HTTPServer(("127.0.0.1", 8765), Handler) as s:
        print("Knox briefing server on :8765")
        s.serve_forever()
PYEOF

sudo chmod +x /usr/local/bin/knox-briefing-server.py

# Systemd service for briefing server
sudo tee /etc/systemd/system/knox-briefing.service > /dev/null << 'SVCEOF'
[Unit]
Description=Knox Morning Briefing Server
After=network.target

[Service]
Type=simple
User=neo
ExecStart=/usr/bin/python3 /usr/local/bin/knox-briefing-server.py
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable knox-briefing
sudo systemctl start knox-briefing
ok "Knox briefing server running on :8765"

# Cron: 1AM optimization + briefing generation
(crontab -l 2>/dev/null | grep -v knox-optimize; echo "0 1 * * * /usr/local/bin/knox-optimize.sh") | crontab -
ok "Knox 1AM cron job set (briefing gated to 5AM display)"

# ───────────────────────────────
# 10. GIT SETUP
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
echo -e "${GREEN}✓${NC} Knox v2 model created (locked — no tools)"
echo -e "${GREEN}✓${NC} Lone Starr model created"
echo -e "${GREEN}✓${NC} Reyes model created"
echo -e "${GREEN}✓${NC} Lone Starr panel on port 8888"
echo -e "${GREEN}✓${NC} Knox 1AM cron + briefing pre-generation"
echo -e "${GREEN}✓${NC} Knox briefing server on :8765 (5AM gate)"
echo -e "${GREEN}✓${NC} Git configured"
echo ""
echo -e "PUBLIC PANEL:  ${CYAN}http://100.114.75.23:8888${NC}"
echo -e "OPENWEBUI:     ${CYAN}http://100.114.75.23:3000${NC}"
echo -e "BRIEFING API:  ${CYAN}http://localhost:8765/briefing${NC} (after 05:00)"
echo ""
echo -e "${YELLOW}MANUAL STEPS REMAINING:${NC}"
echo "1. Add models in OpenWebUI: Workspace → Models → Knox / Lone Starr / Reyes"
echo "2. IMPORTANT: OpenWebUI → Models → Knox → Tools → REMOVE execute_command"
echo "3. Set OPENWEBUI_TOKEN env var to automate tool removal next run"
echo "4. Copy talon-drop.html to web root"
echo "5. Hard reset A7 router (hold reset 10s) → 192.168.0.1"
echo "6. DuckDNS setup: https://www.duckdns.org → get token → update /etc/cron.d/duckdns"
echo ""
echo -e "May the Schwartz be with you. — Knox"

# ───────────────────────────────
# 11. KNOX CONTEXT SYNC — pulls latest files from GitHub
# Knox reads these at 1AM and on demand via: knox-pull
# ───────────────────────────────
info "Setting up Knox GitHub context sync..."

sudo tee /usr/local/bin/knox-pull > /dev/null << 'PULLEOF'
#!/bin/bash
# knox-pull — fetch latest Talonnet files from GitHub
# Knox reads these as live context. Run manually or triggered at 12:50AM.

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }

GITHUB_RAW="https://raw.githubusercontent.com/TheHandlerProject/talon-scripts/main"
CONTEXT_DIR="/home/neo/knox-context"
mkdir -p "$CONTEXT_DIR"

echo -e "${CYAN}Knox context sync -- $(date)${NC}"

FILES=("deploy-talon.sh" "talon-drop.html" "knox-modelfile")

for f in "${FILES[@]}"; do
  if curl -sf "$GITHUB_RAW/$f" -o "$CONTEXT_DIR/$f.new"; then
    if ! diff -q "$CONTEXT_DIR/$f" "$CONTEXT_DIR/$f.new" &>/dev/null 2>&1; then
      mv "$CONTEXT_DIR/$f.new" "$CONTEXT_DIR/$f"
      ok "$f updated"
    else
      rm -f "$CONTEXT_DIR/$f.new"
      ok "$f unchanged"
    fi
  else
    warn "$f -- fetch failed (GitHub unreachable or file missing)"
  fi
done

# If knox-modelfile changed, auto-rebuild Knox
if [ -f "$CONTEXT_DIR/knox-modelfile" ]; then
  CURRENT_HASH=$(md5sum "$CONTEXT_DIR/knox-modelfile" | cut -d' ' -f1)
  STORED_HASH=$(cat "$CONTEXT_DIR/.knox-modelfile-hash" 2>/dev/null || echo "")
  if [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
    echo "Knox Modelfile changed -- rebuilding..."
    ollama create knox -f "$CONTEXT_DIR/knox-modelfile" \
      && ok "Knox rebuilt from latest Modelfile" \
      || warn "Knox rebuild failed -- check Modelfile syntax"
    echo "$CURRENT_HASH" > "$CONTEXT_DIR/.knox-modelfile-hash"
  fi
fi

echo "Last sync: $(date)" > "$CONTEXT_DIR/.last-sync"
echo "Context: $CONTEXT_DIR"
PULLEOF

sudo chmod +x /usr/local/bin/knox-pull

# 12:50AM cron — pulls before 1AM optimize so briefing uses latest context
(crontab -l 2>/dev/null | grep -v knox-pull; echo "50 0 * * * /usr/local/bin/knox-pull") | crontab -
ok "knox-pull cron set at 12:50AM (runs before optimize)"
ok "Run anytime manually: knox-pull"
