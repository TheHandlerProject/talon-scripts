#!/bin/bash
# knox-memory.sh — persistent Knox memory system
# Knox reads a running memory file before every session
# Writes observations after every session
# Runs automatically via knox-ask and knox-report

MEMORY_FILE="/home/neo/knox-logs/knox-memory.txt"
CONTEXT_FILE="/home/neo/knox-logs/claude-context.txt"
LOG="/home/neo/knox-logs/knox-memory.log"
mkdir -p /home/neo/knox-logs

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# ── INITIALIZE MEMORY FILE IF MISSING ────────────────────
if [ ! -f "$MEMORY_FILE" ]; then
cat > "$MEMORY_FILE" << 'MEMEOF'
=== KNOX PERSISTENT MEMORY ===
Last updated: never

COMPLETED TASKS:
- Knox v4 deployed with full network knowledge
- talon-doctor installed (5min watchdog)
- UFW hardened: deny incoming, allow 22/tcp tailscale, 8888, 8123
- Wonderwoman firewall opened port 11434 to Talon
- Fail2ban installed
- SSH restricted to Tailscale only
- DuckDNS configured for talonnet.duckdns.org
- knox-queue approval system installed
- Cloudflare tunnel setup in progress (DNS propagating)

PENDING:
- Cloudflare tunnel token (DNS propagating for sfer.me)
- Router extroot (A7)
- Reyes SSH cert
- Fix thehandlerproject.github.io
- Wonderwoman auto-routing for heavy models

KNOWN ISSUES:
- knox-briefing had port conflict with motioneye on 8765 (fixed)
- GitHub raw serving sometimes cached — use direct tee installs as fallback
- talon-doctor.sh GitHub fetch unreliable — installed directly via tee

NETWORK STATE:
- Talon: 100.114.75.23 | 10.0.0.33 LAN
- Wonderwoman: 100.109.52.96 | port 11434 open to Talon
- DuckDNS: talonnet.duckdns.org → 24.21.76.151
- Cloudflare: sfer.me added, nameservers updating
- DMZ: set to 10.0.0.33 (can remove after tunnel live)
MEMEOF
echo "Memory file initialized"
fi

# ── UPDATE MEMORY WITH LATEST CONTEXT ────────────────────
update_memory() {
  local NOTE="$1"
  echo "[$(ts)] $NOTE" >> "$MEMORY_FILE"
  echo "[$(ts)] Memory updated: $NOTE" >> "$LOG"
}

# ── READ MEMORY + CONTEXT FOR KNOX SESSION ───────────────
build_knox_context() {
  local MEMORY=$(cat "$MEMORY_FILE" 2>/dev/null | tail -50)
  local CONTEXT=$(grep -E "^(Talon:|Wonderwoman:|Docker:|Ollama:|Internet:|Tailscale:|Disk:|RAM:|knox-briefing:|lonestarr-panel:)" "$CONTEXT_FILE" 2>/dev/null | head -20)
  echo "=== KNOX MEMORY ===
$MEMORY

=== LIVE STATE ===
$CONTEXT"
}

# Export for use by other scripts
export -f build_knox_context
export -f update_memory

# If called with an argument, update memory
if [ -n "$1" ]; then
  update_memory "$1"
  echo "Memory updated: $1"
else
  echo "Knox memory initialized at $MEMORY_FILE"
fi
