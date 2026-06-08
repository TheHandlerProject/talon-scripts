#!/bin/sh
# start-inspection.sh — One-command startup for AI Metrology Inspection Station
# Usage: ./start-inspection.sh [stop|restart|status]
# Handles: v4l2loopback, DroidCam, Flask server

set -e

INSPECTION_DIR="${HOME}/inspection"
PHONE_IP="10.0.0.29"
PHONE_PORT="4747"
VIDEO_DEV="/dev/video2"
VIDEO_NR="2"
PID_FILE="${INSPECTION_DIR}/.droidcam.pid"

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

# ── Load v4l2loopback ─────────────────────────────────────────────────────────
load_loopback() {
    # Kill anything using the device first
    sudo fuser -k "${VIDEO_DEV}" 2>/dev/null || true

    # Unload if already loaded
    if lsmod | grep -q v4l2loopback; then
        log_step "Reloading v4l2loopback..."
        sudo rmmod v4l2loopback 2>/dev/null || true
        sleep 1
    fi

    log_step "Loading v4l2loopback..."
    sudo modprobe v4l2loopback \
        devices=1 \
        video_nr="${VIDEO_NR}" \
        card_label="DroidCam" \
        exclusive_caps=1
    sudo chmod 666 "${VIDEO_DEV}"
    log_info "v4l2loopback ready at ${VIDEO_DEV}"
}

# ── Start DroidCam ────────────────────────────────────────────────────────────
start_droidcam() {
    # Kill any existing droidcam process
    if [ -f "${PID_FILE}" ]; then
        old_pid="$(cat "${PID_FILE}")"
        kill "${old_pid}" 2>/dev/null || true
        rm -f "${PID_FILE}"
    fi
    pkill -f "droidcam-cli" 2>/dev/null || true
    sleep 1

    log_step "Connecting DroidCam (${PHONE_IP}:${PHONE_PORT})..."
    log_warn "Make sure DroidCam app is open on your phone first!"

    droidcam-cli -v -dev="${VIDEO_DEV}" "${PHONE_IP}" "${PHONE_PORT}" &
    echo $! > "${PID_FILE}"

    # Wait up to 8s for DroidCam to establish stream
    retries=8
    while [ "${retries}" -gt 0 ]; do
        if sudo v4l2-ctl -d "${VIDEO_DEV}" --get-fmt-video >/dev/null 2>&1; then
            log_info "DroidCam streaming"
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done

    log_warn "DroidCam did not confirm stream — continuing anyway"
    log_warn "If camera is blank, check phone screen shows camera preview"
}

# ── Stop everything ───────────────────────────────────────────────────────────
stop_all() {
    log_info "Stopping inspection server..."
    cd "${INSPECTION_DIR}" && ./deploy.sh --stop 2>/dev/null || true

    log_info "Stopping DroidCam..."
    if [ -f "${PID_FILE}" ]; then
        kill "$(cat "${PID_FILE}")" 2>/dev/null || true
        rm -f "${PID_FILE}"
    fi
    pkill -f "droidcam-cli" 2>/dev/null || true

    log_info "All services stopped"
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
    echo ""
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
        printf "${C_GREEN}●${C_RESET} DroidCam running (PID $(cat "${PID_FILE}"))\n"
    else
        printf "${C_RED}●${C_RESET} DroidCam stopped\n"
    fi
    cd "${INSPECTION_DIR}" && ./deploy.sh --status
}

# ── Main start ────────────────────────────────────────────────────────────────
start_all() {
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   Metrology Inspection Station       ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""

    load_loopback
    start_droidcam

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
