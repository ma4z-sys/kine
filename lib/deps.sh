#!/usr/bin/env bash
# ─── Kine Dependency Manager ─────────────────────────────────
# Checks and installs required system dependencies

# ─── Individual Checks ───────────────────────────────────────

check_waydroid() {
    if command -v waydroid &>/dev/null; then
        kine_success "waydroid:       $(waydroid --version 2>/dev/null | head -1 || echo 'installed')"
        return 0
    fi
    return 1
}

check_lxc() {
    if command -v lxc-start &>/dev/null || command -v lxc &>/dev/null; then
        kine_success "lxc:            $(lxc-start --version 2>/dev/null || echo 'installed')"
        return 0
    fi
    return 1
}

check_aapt() {
    if command -v aapt &>/dev/null || command -v aapt2 &>/dev/null; then
        kine_success "aapt/aapt2:     installed (APK parsing enabled)"
        return 0
    fi
    kine_warn "aapt/aapt2:     not found (package name extraction disabled)"
    return 1
}

check_xwayland() {
    if command -v Xwayland &>/dev/null; then
        kine_success "XWayland:       installed"
        return 0
    fi
    kine_warn "XWayland:       not found (X11 fallback unavailable)"
    return 1
}

check_python3() {
    if command -v python3 &>/dev/null; then
        kine_success "python3:        $(python3 --version 2>&1)"
        return 0
    fi
    return 1
}

check_xxd() {
    if command -v xxd &>/dev/null || command -v od &>/dev/null; then
        kine_success "hex tools:      available (APK validation enabled)"
        return 0
    fi
    return 1
}

# ─── Kernel Module Checks ─────────────────────────────────────

check_kernel_modules() {
    kine_info "Kernel modules:"

    local binder_ok=false
    local kernel_ver
    kernel_ver=$(uname -r)

    kine_dim "  Kernel: ${kernel_ver}"

    if modinfo binder_linux &>/dev/null 2>&1; then
        kine_success "  binder_linux:   available"
        binder_ok=true
    elif modinfo binder &>/dev/null 2>&1; then
        kine_success "  binder:         available (legacy)"
        binder_ok=true
    elif lsmod | grep -q binder; then
        kine_success "  binder:         already loaded"
        binder_ok=true
    else
        kine_warn "  binder:         not found"
        kine_dim  "  Try: sudo apt install linux-modules-extra-${kernel_ver}"
    fi

    if modinfo ashmem_linux &>/dev/null 2>&1; then
        kine_success "  ashmem_linux:   available"
    else
        kine_dim   "  ashmem_linux:   not found (may not be needed on newer kernels)"
    fi

    $binder_ok
}

# ─── Display Check ────────────────────────────────────────────

check_display_stack() {
    kine_info "Display stack:"

    local display_type
    display_type=$(detect_display_server)

    case "$display_type" in
        wayland)
            kine_success "  Wayland:        active (${WAYLAND_DISPLAY:-wayland-0})"
            ;;
        x11)
            kine_success "  X11:            active (${DISPLAY:-:0})"
            ;;
        *)
            kine_warn   "  Display:        not detected"
            ;;
    esac

    local gpu_type
    gpu_type=$(detect_gpu)
    kine_dim "  GPU:            ${gpu_type} rendering"
}

# ─── Install Missing Deps ─────────────────────────────────────

install_waydroid() {
    kine_info "Installing Waydroid..."

    # Add Waydroid repository (Ubuntu/Debian)
    if command -v apt &>/dev/null; then
        kine_dim "Adding Waydroid PPA..."
        sudo apt install -y curl &>/dev/null

        # Official Waydroid install script
        curl -s https://repo.waydro.id | sudo bash &>/dev/null || {
            kine_warn "PPA script failed — trying manual setup..."
            sudo apt install -y software-properties-common &>/dev/null
            sudo add-apt-repository -y ppa:waydroid/waydroid &>/dev/null || true
        }

        sudo apt update -y &>/dev/null
        sudo apt install -y waydroid || {
            kine_error "Waydroid installation failed"
            kine_info  "Manual install: https://waydro.id"
            return 1
        }
    elif command -v pacman &>/dev/null; then
        kine_dim "Arch-based system detected..."
        yay -S waydroid --noconfirm 2>/dev/null || \
        paru -S waydroid --noconfirm 2>/dev/null || {
            kine_error "Install via AUR: yay -S waydroid"
            return 1
        }
    else
        kine_error "Unsupported package manager"
        kine_info  "Install Waydroid manually: https://waydro.id"
        return 1
    fi

    kine_success "Waydroid installed"
}

install_lxc() {
    if command -v apt &>/dev/null; then
        sudo apt install -y lxc lxc-utils lxcfs &>/dev/null
        kine_success "LXC installed"
    fi
}

install_aapt() {
    if command -v apt &>/dev/null; then
        sudo apt install -y aapt 2>/dev/null || sudo apt install -y aapt2 2>/dev/null || true
    fi
}

install_xwayland() {
    if command -v apt &>/dev/null; then
        sudo apt install -y xwayland &>/dev/null
        kine_success "XWayland installed"
    fi
}

# ─── Main Deps Check ─────────────────────────────────────────

require_deps() {
    kine_step "Checking dependencies"

    local missing=()

    echo ""
    check_xxd || true

    # Critical: Waydroid
    if ! check_waydroid; then
        missing+=("waydroid")
    fi

    # Important: LXC
    if ! check_lxc; then
        missing+=("lxc")
    fi

    # Optional but useful
    check_aapt || true
    check_xwayland || true
    check_python3 || true

    echo ""
    kine_info "Kernel:"
    check_kernel_modules || true

    echo ""
    check_display_stack

    # Install missing critical deps
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        kine_warn "Missing required dependencies: ${missing[*]}"
        echo -n "  Install missing dependencies now? [Y/n] "
        read -r answer
        answer="${answer:-Y}"

        if [[ "${answer,,}" == "y" ]]; then
            for dep in "${missing[@]}"; do
                case "$dep" in
                    waydroid) install_waydroid ;;
                    lxc)      install_lxc ;;
                esac
            done
        else
            kine_error "Cannot proceed without required dependencies"
            kine_info  "Install manually and re-run: kine init <model>"
            exit 1
        fi
    fi

    kine_success "All required dependencies satisfied"
}

# Quick check (no install prompts) for non-init commands
check_deps_quick() {
    local ok=true
    command -v waydroid &>/dev/null || { kine_error "waydroid not found — run: kine init <model>"; ok=false; }
    $ok
}
