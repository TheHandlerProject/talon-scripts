#!/bin/bash
# knox-pull v2 — fetch latest files from GitHub with verification
# Runs at 12:50AM via cron. Verifies content after fetch.

GITHUB_RAW="https://raw.githubusercontent.com/TheHandlerProject/talon-scripts/main"
CONTEXT_DIR="/home/neo/knox-context"
LOG="/home/neo/knox-logs/knox-pull.log"
mkdir -p "$CONTEXT_DIR" /home/neo/knox-logs

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

log "=== knox-pull start ==="

# Verify GitHub is reachable first
if ! curl -sf --max-time 10 "https://github.com" &>/dev/null; then
  log "GitHub unreachable — skipping pull"
  exit 1
fi

# Fetch with content verification
fetch_verify() {
  local FILE="$1"
  local VERIFY_STRING="$2"
  local DEST="$CONTEXT_DIR/$FILE"
  local TMP="/tmp/knox-pull-$FILE"

  # Fetch with cache-bust
  HTTP_CODE=$(curl -sf --max-time 30 \
    -H "Cache-Control: no-cache" \
    "$GITHUB_RAW/$FILE?t=$(date +%s)" \
    -o "$TMP" -w "%{http_code}")

  if [ "$HTTP_CODE" != "200" ]; then
    log "FAIL: $FILE returned HTTP $HTTP_CODE"
    return 1
  fi

  # Verify content if string provided
  if [ -n "$VERIFY_STRING" ] && ! grep -q "$VERIFY_STRING" "$TMP"; then
    log "FAIL: $FILE content verification failed"
    return 1
  fi

  mv "$TMP" "$DEST"
  log "OK: $FILE fetched and verified"
  return 0
}

fetch_verify "deploy-talon.sh"        "TALON"
fetch_verify "talon-drop.html"        "html"
fetch_verify "knox-modelfile-v5.sh"    "FROM mistral"
fetch_verify "knox-context-now.sh"    "claude-context"
fetch_verify "knox-queue.sh"          "knox-queue"
fetch_verify "knox-approve.sh"        "knox-approve"
fetch_verify "talon-preflight.sh"     "Pre-flight"
fetch_verify "knox-memory.sh"         "knox-memory"
fetch_verify "knox-ww-router.sh"      "knox-run"
fetch_verify "knox-cloudflare.sh"     "cloudflared"

# Check if knox-modelfile changed — rebuild if so
NEW_HASH=$(md5sum "$CONTEXT_DIR/knox-modelfile-v5.sh" 2>/dev/null | cut -d' ' -f1)
OLD_HASH=$(cat "$CONTEXT_DIR/.knox-modelfile-hash" 2>/dev/null)
if [ "$NEW_HASH" != "$OLD_HASH" ]; then
  log "Knox modelfile changed — rebuilding..."
  ollama create knox -f "$CONTEXT_DIR/knox-modelfile-v5.sh" >> "$LOG" 2>&1 \
    && log "Knox rebuilt successfully" \
    || log "Knox rebuild FAILED"
  echo "$NEW_HASH" > "$CONTEXT_DIR/.knox-modelfile-hash"
fi

echo "$(ts)" > "$CONTEXT_DIR/.last-sync"
log "=== knox-pull complete ==="
