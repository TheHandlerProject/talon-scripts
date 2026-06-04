#!/bin/bash
# knox-ask v2 — query Knox with trimmed context (no hanging)
# Usage: knox-ask "question"
#        knox-ask  (interactive)

CONTEXT_FILE="/home/neo/knox-logs/claude-context.txt"

# Build trimmed context — key facts only, no fluff
if [ -f "$CONTEXT_FILE" ]; then
  CONTEXT=$(grep -E "^(Talon:|Wonderwoman:|Docker:|Ollama:|Internet:|Tailscale:|Disk:|RAM:|knox-briefing:|lonestarr-panel:)" "$CONTEXT_FILE" | head -20)
else
  CONTEXT="Context file not found. Check /home/neo/knox-logs/"
fi

PROMPT="${*:-What needs attention on Talonnet right now?}"

ollama run knox "System state:
$CONTEXT

Question: $PROMPT"
