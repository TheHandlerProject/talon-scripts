#!/bin/sh
# start-inspection.sh — One-command startup for AI Metrology Inspection Station
# Usage: ./start-inspection.sh [stop|restart|status]
# Camera: DroidCam HTTP stream (no loopback needed)

set -e

INSPECTION_DIR="${HOME}/inspection"
PHONE_IP="10.0.0.29"
PHONE_PORT="4747"

# ── Colors ───────────────────────────────────────────────────────────────────
C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''
if [ -t 1 ]; then
    C_RESET='\033[0m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'
fi
log_info()  { printf "${C_GREEN}[INFO]${C_RESET}  %s\n" "$1"; }
log_warn()  { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$1"; }
log_error() { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$1" >&2; }
log_step()  { printf "${C_CYAN}[....] %s${C_RESET}\n" "$1"; }

# ── Check DroidCam reachable ──────────────────────────────────────────────────
check_droidcam() {
    log_step "Checking DroidCam at ${PHONE_IP}:${PHONE_PORT}..."
    log_warn "Make sure DroidCam app is open on your phone!"
    retries=10
    while [ "${retries}" -gt 0 ]; do
        if curl -sf --max-time 2 "http://${PHONE_IP}:${PHONE_PORT}/video" \
            -o /dev/null 2>/dev/null; then
            log_info "DroidCam reachable"
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    log_warn "DroidCam not responding — starting anyway, check phone"
}

# ── Stop everything ───────────────────────────────────────────────────────────
stop_all() {
    log_info "Stopping inspection server..."
    cd "${INSPECTION_DIR}" && ./deploy.sh --stop 2>/dev/null || true
    log_info "Done"
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
    cd "${INSPECTION_DIR}" && ./deploy.sh --status
}

# ── Main start ────────────────────────────────────────────────────────────────
start_all() {
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   Metrology Inspection Station       ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""

    check_droidcam

    log_step "Starting inspection server..."
    cd "${INSPECTION_DIR}"
    ./deploy.sh --start

    echo ""
    log_info "Ready — open http://$(hostname -I | awk '{print $1}'):5000"
    echo ""
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:-start}" in
    start)   start_all ;;
    stop)    stop_all ;;
    restart) stop_all; sleep 2; start_all ;;
    status)  show_status ;;
    *)
        printf "Usage: %s [start|stop|restart|status]\n" "$0"
        exit 1
        ;;
esac
