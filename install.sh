#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════╗
# ║                  Kine Installer Script                    ║
# ╚═══════════════════════════════════════════════════════════╝
# Run this script to install kine system-wide:
#   sudo bash install.sh

set -euo pipefail

KINE_INSTALL_DIR="/opt/kine"
KINE_BIN_LINK="/usr/local/bin/kine"
KINE_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_GREEN="\033[38;5;84m"
C_CYAN="\033[38;5;51m"
C_YELLOW="\033[38;5;220m"
C_RED="\033[38;5;203m"
C_WHITE="\033[38;5;255m"
C_BOLD="\033[1m"
C_RESET="\033[0m"

info()    { echo -e "  ${C_CYAN}→${C_RESET}  ${C_WHITE}$*${C_RESET}"; }
success() { echo -e "  ${C_GREEN}✓${C_RESET}  $*"; }
warn()    { echo -e "  ${C_YELLOW}⚠${C_RESET}  $*"; }
error()   { echo -e "  ${C_RED}✗${C_RESET}  $*" >&2; }

banner() {
    echo -e "
  ${C_BOLD}${C_CYAN}
  ██╗  ██╗██╗███╗   ██╗███████╗
  ██║ ██╔╝██║████╗  ██║██╔════╝
  █████╔╝ ██║██╔██╗ ██║█████╗
  ██╔═██╗ ██║██║╚██╗██║██╔══╝
  ██║  ██╗██║██║ ╚████║███████╗
  ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝${C_RESET}

  ${C_WHITE}Android APK Launcher for Linux${C_RESET}
  ${C_CYAN}────────────────────────────────${C_RESET}
"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This installer requires root privileges"
        info  "Run: sudo bash install.sh"
        exit 1
    fi
}

check_os() {
    if ! command -v apt &>/dev/null && ! command -v pacman &>/dev/null; then
        warn "Non-Debian/Arch system detected"
        warn "Manual dependency installation may be required"
    fi

    local kernel_ver
    kernel_ver=$(uname -r | cut -d. -f1,2)
    info "Kernel version: ${kernel_ver}"

    # Warn if kernel < 4.14 (minimum for binder)
    local major minor
    major=$(echo "$kernel_ver" | cut -d. -f1)
    minor=$(echo "$kernel_ver" | cut -d. -f2)
    if (( major < 4 )) || (( major == 4 && minor < 14 )); then
        warn "Kernel ${kernel_ver} may not support Android binder"
        warn "Recommended: kernel 5.x+ for best compatibility"
    fi
}

install_files() {
    info "Installing kine to ${KINE_INSTALL_DIR}..."

    # Create install directory
    mkdir -p "${KINE_INSTALL_DIR}"

    # Copy files
    cp -r "${KINE_SRC_DIR}/bin" "${KINE_INSTALL_DIR}/"
    cp -r "${KINE_SRC_DIR}/lib" "${KINE_INSTALL_DIR}/"

    # Set permissions
    chmod +x "${KINE_INSTALL_DIR}/bin/kine"
    chmod 644 "${KINE_INSTALL_DIR}/lib/"*.sh

    success "Files installed to ${KINE_INSTALL_DIR}"
}

create_symlink() {
    info "Creating symlink: ${KINE_BIN_LINK}"

    # Remove existing link if present
    [[ -L "${KINE_BIN_LINK}" ]] && rm "${KINE_BIN_LINK}"

    ln -s "${KINE_INSTALL_DIR}/bin/kine" "${KINE_BIN_LINK}"
    success "Symlink created: kine → ${KINE_INSTALL_DIR}/bin/kine"
}

setup_sudoers() {
    info "Configuring sudoers for Waydroid..."

    local sudoers_file="/etc/sudoers.d/kine"
    cat > "${sudoers_file}" <<'EOF'
# Kine - Allow running Waydroid without password prompt
# Required for: container start/stop, kernel modules, systemctl
%sudo ALL=(root) NOPASSWD: /usr/bin/waydroid, /usr/sbin/modprobe, /usr/bin/systemctl start waydroid-container, /usr/bin/systemctl stop waydroid-container, /usr/bin/systemctl restart waydroid-container
EOF
    chmod 440 "${sudoers_file}"
    success "Sudoers configured (${sudoers_file})"
}

install_system_service() {
    info "Installing systemd service..."

    cat > "/etc/systemd/system/waydroid-container.service" <<'EOF'
[Unit]
Description=Waydroid Android Container
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/waydroid container start
ExecStop=/usr/bin/waydroid container stop
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload &>/dev/null
    success "systemd service installed"
}

print_next_steps() {
    echo -e "
  ${C_BOLD}${C_GREEN}Installation Complete!${C_RESET}

  ${C_WHITE}Next steps:${C_RESET}

  ${C_CYAN}1.${C_RESET} Initialize the Android runtime:
     ${C_WHITE}kine init pixel5${C_RESET}

  ${C_CYAN}2.${C_RESET} Launch an APK:
     ${C_WHITE}kine launch ~/Downloads/myapp.apk${C_RESET}

  ${C_CYAN}3.${C_RESET} Check status anytime:
     ${C_WHITE}kine status${C_RESET}

  ${C_CYAN}Note:${C_RESET} First init downloads ~1GB Android image
        Make sure you have a good internet connection.

"
}

main() {
    banner
    check_root
    check_os
    install_files
    create_symlink
    setup_sudoers
    install_system_service
    print_next_steps
}

main "$@"
