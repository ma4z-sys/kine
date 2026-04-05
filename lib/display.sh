#!/usr/bin/env bash
# ─── Kine Display Library ────────────────────────────────────
# Detects display server (Wayland/X11) and configures environment

KINE_DISPLAY_CONFIG="${KINE_HOME}/config/display.env"

# ─── Detection ───────────────────────────────────────────────

detect_display_server() {
    # Check for Wayland first
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && [[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY}" ]]; then
        echo "wayland"
        return
    fi

    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        echo "wayland"
        return
    fi

    # Check for running Wayland compositor
    if pgrep -x "gnome-shell\|sway\|weston\|kwin_wayland\|mutter" &>/dev/null; then
        if [[ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wayland-0" ]]; then
            echo "wayland"
            return
        fi
    fi

    # Fallback to X11
    if [[ -n "${DISPLAY:-}" ]]; then
        echo "x11"
        return
    fi

    echo "unknown"
}

detect_desktop_env() {
    local de="${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-unknown}}"
    echo "${de,,}"  # lowercase
}

detect_gpu() {
    local gpu_type="software"

    # Check for GPU
    if command -v glxinfo &>/dev/null; then
        local renderer
        renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -1 || echo "")
        if echo "$renderer" | grep -qiE "nvidia|amd|intel|radeon|mesa"; then
            gpu_type="hardware"
        fi
    elif ls /dev/dri/renderD* &>/dev/null 2>&1; then
        gpu_type="hardware"
    fi

    echo "$gpu_type"
}

# ─── Setup Functions ─────────────────────────────────────────

setup_display_wayland() {
    kine_step "Configuring Wayland display backend"

    local xdg_runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local wayland_sock="${WAYLAND_DISPLAY:-wayland-0}"

    # Ensure Wayland socket exists
    if [[ ! -S "${xdg_runtime}/${wayland_sock}" ]]; then
        kine_warn "Wayland socket not found at ${xdg_runtime}/${wayland_sock}"
        kine_info "Attempting XDG_RUNTIME_DIR discovery..."

        # Try common paths
        for uid_path in "/run/user/$(id -u)" "${HOME}/.wayland"; do
            if [[ -S "${uid_path}/wayland-0" ]]; then
                xdg_runtime="$uid_path"
                break
            fi
        done
    fi

    # Write display config
    mkdir -p "${KINE_HOME}/config"
    cat > "${KINE_DISPLAY_CONFIG}" <<EOF
# Kine display configuration - Wayland mode
DISPLAY_BACKEND=wayland
XDG_SESSION_TYPE=wayland
XDG_RUNTIME_DIR=${xdg_runtime}
WAYLAND_DISPLAY=${wayland_sock}
KINE_DISPLAY_READY=1
EOF

    # Export for current session
    export XDG_SESSION_TYPE=wayland
    export XDG_RUNTIME_DIR="${xdg_runtime}"
    export WAYLAND_DISPLAY="${wayland_sock}"

    kine_success "Wayland backend configured (socket: ${xdg_runtime}/${wayland_sock})"
}

setup_display_x11() {
    kine_step "Configuring X11 display backend"

    local display="${DISPLAY:-:0}"

    # Allow local connections (needed for Waydroid on X11)
    if command -v xhost &>/dev/null; then
        xhost +local: &>/dev/null 2>&1 || kine_warn "xhost command failed (non-critical)"
    fi

    # Ensure XWayland is running if on Wayland session
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        kine_info "Wayland session detected — ensuring XWayland is available"
        if ! pgrep -x Xwayland &>/dev/null; then
            kine_warn "XWayland not running. Attempting to start..."
            Xwayland "${display}" &>/dev/null &
            sleep 1
            if ! pgrep -x Xwayland &>/dev/null; then
                kine_error "XWayland could not be started. Install: sudo apt install xwayland"
                return 1
            fi
        fi
        kine_success "XWayland is running on ${display}"
    fi

    # Write display config
    mkdir -p "${KINE_HOME}/config"
    cat > "${KINE_DISPLAY_CONFIG}" <<EOF
# Kine display configuration - X11 mode
DISPLAY_BACKEND=x11
DISPLAY=${display}
WAYLAND_DISPLAY=
XDG_SESSION_TYPE=x11
KINE_DISPLAY_READY=1
EOF

    export DISPLAY="${display}"
    unset WAYLAND_DISPLAY

    kine_success "X11 backend configured (display: ${display})"
}

# ─── Smart Display Setup with Fallback ───────────────────────

setup_display() {
    local preferred="${1:-auto}"
    local display_server

    kine_step "Detecting display server"

    if [[ "$preferred" == "auto" ]]; then
        display_server=$(detect_display_server)
    else
        display_server="$preferred"
    fi

    kine_dim "Display server: ${display_server}"
    kine_dim "Desktop environment: $(detect_desktop_env)"
    kine_dim "GPU: $(detect_gpu)"

    case "$display_server" in
        wayland)
            kine_info "Display server: Wayland"
            if ! setup_display_wayland; then
                kine_warn "Wayland setup failed — falling back to X11"
                setup_display_x11
            fi
            ;;
        x11)
            kine_info "Display server: X11"
            setup_display_x11
            ;;
        *)
            kine_warn "Could not detect display server — trying X11 defaults"
            export DISPLAY="${DISPLAY:-:0}"
            setup_display_x11
            ;;
    esac

    # Save GPU info to config
    echo "GPU_MODE=$(detect_gpu)" >> "${KINE_DISPLAY_CONFIG}"
}

# Load previously saved display config
load_display_config() {
    if [[ -f "${KINE_DISPLAY_CONFIG}" ]]; then
        # shellcheck disable=SC1090
        source "${KINE_DISPLAY_CONFIG}"
        return 0
    fi
    return 1
}

# Attempt to fix common display errors
fix_display_error() {
    local error_msg="${1:-}"
    kine_warn "Display error detected: ${error_msg}"

    local backend
    backend=$(load_display_config && echo "${DISPLAY_BACKEND:-auto}" || echo "auto")

    kine_info "Attempting automatic display fix..."

    if [[ "$backend" == "wayland" ]]; then
        kine_dim "Switching to X11 fallback..."
        setup_display_x11
    else
        kine_dim "Refreshing X11 display access..."
        xhost +local: &>/dev/null 2>&1 || true
        export DISPLAY="${DISPLAY:-:0}"
    fi

    kine_success "Display configuration refreshed"
}
