#!/usr/bin/env bash
# ─── Kine Logging Library ────────────────────────────────────

KINE_LOG_DIR="${KINE_HOME}/logs"
KINE_LOG_FILE="${KINE_LOG_DIR}/kine.log"

# ANSI colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_GREEN="\033[38;5;84m"
C_BLUE="\033[38;5;75m"
C_YELLOW="\033[38;5;220m"
C_RED="\033[38;5;203m"
C_CYAN="\033[38;5;51m"
C_GRAY="\033[38;5;244m"
C_WHITE="\033[38;5;255m"

# Ensure log directory exists
_ensure_log_dir() {
    mkdir -p "${KINE_LOG_DIR}" 2>/dev/null || true
}

# Internal log to file (silent)
_log_file() {
    local level="$1"
    local msg="$2"
    _ensure_log_dir
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}" >> "${KINE_LOG_FILE}" 2>/dev/null || true
}

# ─── Public log functions ─────────────────────────────────────

kine_info() {
    echo -e "  ${C_BLUE}${C_BOLD}→${C_RESET}  ${C_WHITE}$*${C_RESET}"
    _log_file "INFO" "$*"
}

kine_success() {
    echo -e "  ${C_GREEN}${C_BOLD}✓${C_RESET}  ${C_GREEN}$*${C_RESET}"
    _log_file "OK" "$*"
}

kine_warn() {
    echo -e "  ${C_YELLOW}${C_BOLD}⚠${C_RESET}  ${C_YELLOW}$*${C_RESET}"
    _log_file "WARN" "$*"
}

kine_error() {
    echo -e "  ${C_RED}${C_BOLD}✗${C_RESET}  ${C_RED}$*${C_RESET}" >&2
    _log_file "ERROR" "$*"
}

kine_step() {
    echo -e "\n  ${C_CYAN}${C_BOLD}◆ $*${C_RESET}"
    _log_file "STEP" "$*"
}

kine_dim() {
    echo -e "  ${C_GRAY}${C_DIM}  $*${C_RESET}"
    _log_file "DEBUG" "$*"
}

kine_header() {
    local msg="$*"
    local len=${#msg}
    local line
    line=$(printf '─%.0s' $(seq 1 $((len + 4))))
    echo -e "\n  ${C_BOLD}${C_CYAN}┌${line}┐${C_RESET}"
    echo -e "  ${C_BOLD}${C_CYAN}│  ${C_WHITE}${msg}${C_CYAN}  │${C_RESET}"
    echo -e "  ${C_BOLD}${C_CYAN}└${line}┘${C_RESET}\n"
}

kine_divider() {
    echo -e "  ${C_GRAY}${C_DIM}────────────────────────────────────────${C_RESET}"
}

kine_spinner() {
    local pid="$1"
    local msg="$2"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}${frames[$i]}${C_RESET}  ${C_WHITE}%s${C_RESET}" "$msg"
        i=$(( (i+1) % ${#frames[@]} ))
        sleep 0.08
    done
    tput cnorm 2>/dev/null || true
    printf "\r  ${C_GREEN}✓${C_RESET}  ${C_WHITE}%s${C_RESET}\n" "$msg"
    _log_file "SPIN_DONE" "$msg"
}
