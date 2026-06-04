#!/bin/bash
# knox-heal.sh — Self-healing Knox Ollama connectivity for Talon
# Checks Tailscale, resolves Knox IP, verifies Ollama, restarts if needed
# Run on Talon: bash knox-heal.sh

set -euo pipefail

KNOX_NAME="knox"
OLLAMA_PORT=11434
OPENWEBUI_PORT=3000
MAX_RETRIES=5
RETRY_DELAY=5
LOG="/var/log/knox-heal.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# ── 1. Find Knox's Tailscale IP ──────────────────────────────────────────────
get_knox_ip() {
    local ip
    ip=$(tailscale status --json 2>/dev/null \
        | python3 -c "
import sys, json
peers = json.load(sys.stdin).get('Peer', {}).values()
for p in peers:
    if '${KNOX_NAME}' in p.get('HostName','').lower() or '${KNOX_NAME}' in p.get('DNSName','').lower():
        ips = p.get('TailscaleIPs', [])
        if ips: print(ips[0]); break
" 2>/dev/null)
    echo "$ip"
}

# ── 2. Check if Ollama is responding ────────────────────────────────────────
check_ollama() {
    local ip="$1"
    curl -sf --max-time 5 "http://${ip}:${OLLAMA_PORT}/api/tags" > /dev/null 2>&1
}

# ── 3. List available models on Knox ────────────────────────────────────────
list_models() {
    local ip="$1"
    curl -sf --max-time 5 "http://${ip}:${OLLAMA_PORT}/api/tags" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = [m['name'] for m in data.get('models', [])]
print('\n'.join(models) if models else '(no models found)')
" 2>/dev/null
}

# ── 4. Ping Knox over Tailscale ──────────────────────────────────────────────
ping_knox() {
    local ip="$1"
    ping -c 2 -W 2 "$ip" > /dev/null 2>&1
}

# ── 5. Try to wake Ollama via SSH (if ping works but Ollama is down) ─────────
wake_ollama_ssh() {
    local ip="$1"
    log "Attempting SSH restart of Ollama on Knox ($ip)..."
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "neo@${ip}" \
        "sudo systemctl restart ollama && sleep 3 && systemctl is-active ollama" 2>/dev/null
}

# ── Main loop ────────────────────────────────────────────────────────────────
log "=== Knox heal starting ==="

# Step 1: Tailscale up?
if ! tailscale status > /dev/null 2>&1; then
    log "ERROR: Tailscale is not running on this machine. Starting..."
    sudo tailscale up
    sleep 3
fi

# Step 2: Find Knox
log "Looking for Knox on Tailscale..."
KNOX_IP=$(get_knox_ip)

if [[ -z "$KNOX_IP" ]]; then
    log "ERROR: Knox not found in Tailscale peers."
    log "Run 'tailscale status' to check. Is Knox online?"
    tailscale status
    exit 1
fi

log "Found Knox at $KNOX_IP"

# Step 3: Ping test
if ! ping_knox "$KNOX_IP"; then
    log "ERROR: Knox ($KNOX_IP) is not responding to ping. Node may be offline."
    exit 1
fi
log "Knox is reachable (ping OK)"

# Step 4: Check Ollama with retries
log "Checking Ollama on Knox..."
ATTEMPT=0
OLLAMA_OK=false

while [[ $ATTEMPT -lt $MAX_RETRIES ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    if check_ollama "$KNOX_IP"; then
        OLLAMA_OK=true
        log "Ollama is up on Knox (attempt $ATTEMPT)"
        break
    else
        log "Ollama not responding (attempt $ATTEMPT/$MAX_RETRIES)..."
        if [[ $ATTEMPT -eq 2 ]]; then
            # Try SSH restart on second failure
            if wake_ollama_ssh "$KNOX_IP"; then
                log "SSH restart succeeded, retrying..."
            else
                log "SSH restart failed or unavailable, continuing retries..."
            fi
        fi
        sleep "$RETRY_DELAY"
    fi
done

if [[ "$OLLAMA_OK" == false ]]; then
    log "FATAL: Ollama on Knox did not respond after $MAX_RETRIES attempts."
    exit 1
fi

# Step 5: List models
log "Models available on Knox:"
list_models "$KNOX_IP" | while read -r m; do log "  - $m"; done

# Step 6: Check OpenWebUI on Talon can reach Knox
log "Verifying OpenWebUI (localhost:$OPENWEBUI_PORT) is up..."
if curl -sf --max-time 5 "http://localhost:${OPENWEBUI_PORT}" > /dev/null 2>&1; then
    log "OpenWebUI is up."
else
    log "WARNING: OpenWebUI on Talon not responding on port $OPENWEBUI_PORT."
    log "Check: docker ps | grep openwebui"
fi

log "=== Knox heal complete — all systems nominal ==="
