#!/bin/sh
# deploy.sh — AI Metrology Inspection Station
# POSIX sh (not bash) — runs on Zion (Ubuntu) without bashisms
# Usage:
#   ./deploy.sh           — setup venv + install deps + start server
#   ./deploy.sh --setup   — setup only, do not start
#   ./deploy.sh --start   — start only (assumes venv exists)
#   ./deploy.sh --cal     — run spatial calibration interactively
#   ./deploy.sh --verify  — print calibration status and exit
#   ./deploy.sh --stop    — kill running server
#   ./deploy.sh --status  — show whether server is running

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
PID_FILE="${SCRIPT_DIR}/.inspection.pid"
LOG_FILE="${SCRIPT_DIR}/inspection.log"
PYTHON_MIN_MAJOR=3
PYTHON_MIN_MINOR=10

# ── Colors (safe for POSIX) ───────────────────────────────────────────────
C_RESET=''
C_GREEN=''
C_YELLOW=''
C_RED=''
C_CYAN=''
if [ -t 1 ]; then
    C_RESET='\033[0m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_CYAN='\033[0;36m'
fi

log_info()  { printf "${C_GREEN}[INFO]${C_RESET}  %s\n" "$1"; }
log_warn()  { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$1"; }
log_error() { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$1" >&2; }
log_step()  { printf "${C_CYAN}[....] %s${C_RESET}\n" "$1"; }

# ── Helpers ──────────────────────────────────────────────────────────────

check_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "python3 not found. Install with: sudo apt install python3 python3-venv"
        exit 1
    fi
    py_ver="$(python3 -c 'import sys; print(sys.version_info.minor)')"
    py_maj="$(python3 -c 'import sys; print(sys.version_info.major)')"
    if [ "${py_maj}" -lt "${PYTHON_MIN_MAJOR}" ] || \
       [ "${py_maj}" -eq "${PYTHON_MIN_MAJOR}" ] && [ "${py_ver}" -lt "${PYTHON_MIN_MINOR}" ]; then
        log_error "Python >= ${PYTHON_MIN_MAJOR}.${PYTHON_MIN_MINOR} required (found ${py_maj}.${py_ver})"
        exit 1
    fi
    log_info "Python ${py_maj}.${py_ver} OK"
}

check_v4l2() {
    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        log_warn "v4l2-ctl not found — install with: sudo apt install v4l-utils"
        log_warn "Iriun camera detection may need manual config.yaml adjustment"
        return
    fi
    device_count="$(v4l2-ctl --list-devices 2>/dev/null | grep -c '/dev/video' || true)"
    if [ "${device_count}" -eq 0 ]; then
        log_warn "No V4L2 devices found. Is Iriun running on your phone?"
    else
        log_info "V4L2 devices found: ${device_count}"
        v4l2-ctl --list-devices 2>/dev/null | head -20 | while IFS= read -r line; do
            printf "         %s\n" "${line}"
        done
    fi
}

setup_venv() {
    if [ ! -d "${VENV_DIR}" ]; then
        log_step "Creating virtual environment..."
        python3 -m venv "${VENV_DIR}"
        log_info "Venv created at ${VENV_DIR}"
    else
        log_info "Venv exists at ${VENV_DIR}"
    fi

    log_step "Installing/updating dependencies..."
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
    "${VENV_DIR}/bin/pip" install --quiet -r "${SCRIPT_DIR}/requirements.txt"
    log_info "Dependencies installed"
}

start_server() {
    if [ -f "${PID_FILE}" ]; then
        old_pid="$(cat "${PID_FILE}")"
        if kill -0 "${old_pid}" 2>/dev/null; then
            log_warn "Server already running (PID ${old_pid}). Use --stop first."
            exit 0
        else
            rm -f "${PID_FILE}"
        fi
    fi

    log_step "Starting inspection server..."
    cd "${SCRIPT_DIR}"
    "${VENV_DIR}/bin/python" app.py >> "${LOG_FILE}" 2>&1 &
    server_pid=$!
    echo "${server_pid}" > "${PID_FILE}"

    # Wait up to 5s for server to respond
    retries=10
    while [ "${retries}" -gt 0 ]; do
        if curl -sf http://localhost:5000/api/status >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
        retries=$((retries - 1))
    done

    if [ "${retries}" -eq 0 ]; then
        log_error "Server did not respond within 5s. Check ${LOG_FILE}"
        exit 1
    fi

    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost')"
    log_info "Server running (PID ${server_pid})"
    log_info "Dashboard:  http://${host_ip}:5000"
    log_info "Stream:     http://${host_ip}:5000/stream"
    log_info "Log file:   ${LOG_FILE}"
}

stop_server() {
    if [ ! -f "${PID_FILE}" ]; then
        log_warn "No PID file found — server may not be running"
        return
    fi
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}"
        rm -f "${PID_FILE}"
        log_info "Server stopped (PID ${pid})"
    else
        log_warn "PID ${pid} not found — already stopped"
        rm -f "${PID_FILE}"
    fi
}

show_status() {
    if [ -f "${PID_FILE}" ]; then
        pid="$(cat "${PID_FILE}")"
        if kill -0 "${pid}" 2>/dev/null; then
            log_info "Server RUNNING (PID ${pid})"
            curl -s http://localhost:5000/api/status 2>/dev/null | \
                python3 -c "import sys,json; d=json.load(sys.stdin); \
                [print('  '+k+': '+str(v)) for k,v in d.items()]" || true
        else
            log_warn "PID file exists but process ${pid} is not running"
        fi
    else
        log_warn "Server NOT running"
    fi
}

run_calibration() {
    if [ ! -d "${VENV_DIR}" ]; then
        log_error "Venv not found — run ./deploy.sh --setup first"
        exit 1
    fi
    cd "${SCRIPT_DIR}"
    "${VENV_DIR}/bin/python" calibration.py --spatial
}

run_verify() {
    if [ ! -d "${VENV_DIR}" ]; then
        log_error "Venv not found — run ./deploy.sh --setup first"
        exit 1
    fi
    cd "${SCRIPT_DIR}"
    "${VENV_DIR}/bin/python" calibration.py --verify
}

# ── Main ──────────────────────────────────────────────────────────────────

case "${1:-}" in
    --setup)
        check_python
        setup_venv
        ;;
    --start)
        check_v4l2
        start_server
        ;;
    --stop)
        stop_server
        ;;
    --status)
        show_status
        ;;
    --cal)
        run_calibration
        ;;
    --verify)
        run_verify
        ;;
    "")
        check_python
        check_v4l2
        setup_venv
        start_server
        ;;
    *)
        printf "Usage: %s [--setup|--start|--stop|--status|--cal|--verify]\n" "$0"
        exit 1
        ;;
esac
