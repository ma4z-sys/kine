#!/usr/bin/env bash
# ─── Kine Runtime Library ────────────────────────────────────
# Manages Waydroid runtime lifecycle

KINE_RUNTIME_DIR="${KINE_HOME}/runtime"
KINE_CONFIG_DIR="${KINE_HOME}/config"
KINE_RUNTIME_CONFIG="${KINE_CONFIG_DIR}/runtime.conf"

# Waydroid system image info
WAYDROID_IMG_URL_BASE="https://sourceforge.net/projects/waydroid/files/images"

# ─── Prerequisite Checks ─────────────────────────────────────

require_waydroid() {
    if ! command -v waydroid &>/dev/null; then
        kine_error "Waydroid is not installed."
        kine_info  "Run: kine init <model>  (to install and configure automatically)"
        exit 1
    fi
}

check_runtime_initialized() {
    [[ -f "${KINE_RUNTIME_CONFIG}" ]] && grep -q "INITIALIZED=true" "${KINE_RUNTIME_CONFIG}" 2>/dev/null
}

# ─── Kernel Modules ──────────────────────────────────────────

load_kernel_modules() {
    kine_step "Loading Android kernel modules"

    local modules_ok=true

    # Try binderfs (modern kernel ≥ 5.8)
    if modinfo binderfs &>/dev/null 2>&1; then
        if ! lsmod | grep -q binder_linux; then
            kine_dim "Loading binder_linux (binderfs)..."
            sudo modprobe binder_linux num_devices=254 2>/dev/null || {
                kine_warn "binder_linux module failed to load — trying binder..."
                sudo modprobe binder 2>/dev/null || modules_ok=false
            }
        else
            kine_dim "binder_linux already loaded"
        fi
    elif modinfo ashmem_linux &>/dev/null 2>&1; then
        # Older kernel path
        kine_dim "Loading ashmem_linux (legacy)..."
        sudo modprobe ashmem_linux 2>/dev/null || modules_ok=false
        sudo modprobe binder_linux num_devices=254 2>/dev/null || modules_ok=false
    fi

    if $modules_ok; then
        kine_success "Kernel modules ready"
    else
        kine_warn "Some kernel modules failed — Waydroid may still work with built-in binder support"
        kine_dim   "If you see errors, try: sudo apt install linux-modules-extra-$(uname -r)"
    fi
}

# ─── Waydroid Init ───────────────────────────────────────────

runtime_init() {
    local model="${1:-pixel5}"
    local channel="${2:-lineage}"      # lineage (default) | vanilla
    local arch="${3:-$(uname -m)}"

    # Normalize model name
    model="${model//[[:space:]]/_}"
    model="${model,,}"

    kine_header "Initializing Kine Runtime"
    kine_info "Android model profile: ${model}"
    kine_info "Image channel: ${channel}"

    # Create directory structure
    kine_step "Creating Kine directories"
    mkdir -p \
        "${KINE_HOME}/runtime" \
        "${KINE_HOME}/apps" \
        "${KINE_HOME}/cache" \
        "${KINE_HOME}/logs" \
        "${KINE_HOME}/config"
    kine_success "Directory structure created at ~/.kine/"

    # Load kernel modules
    load_kernel_modules

    # Configure display
    setup_display auto

    # Check if waydroid is already initialized
    if waydroid status 2>/dev/null | grep -q "RUNNING\|Session Running"; then
        kine_success "Waydroid is already running"
    else
        kine_step "Initializing Waydroid Android runtime"
        kine_dim "This may take several minutes on first run (downloading ~1GB system image)"
        kine_dim "Image: Android (${channel}) for ${arch}"

        # Run waydroid init
        # Using --force to allow re-init on existing installs
        local init_cmd="sudo waydroid init -s GAPPS -f"

        if [[ "$channel" == "vanilla" ]]; then
            init_cmd="sudo waydroid init -f"
        fi

        kine_dim "Running: ${init_cmd}"

        if ! $init_cmd; then
            kine_error "Waydroid initialization failed"
            kine_info  "Check logs: ~/.kine/logs/kine.log"
            kine_info  "Or run: sudo waydroid log"
            exit 1
        fi

        kine_success "Waydroid initialized"
    fi

    # Start Waydroid container service
    runtime_ensure_started

    # Write runtime config
    mkdir -p "${KINE_CONFIG_DIR}"
    cat > "${KINE_RUNTIME_CONFIG}" <<EOF
# Kine Runtime Configuration
# Generated: $(date)
INITIALIZED=true
MODEL=${model}
CHANNEL=${channel}
ARCH=${arch}
INIT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    kine_divider
    kine_success "Kine runtime initialized successfully!"
    kine_info   "Run apps with: kine launch <app.apk>"
}

# ─── Start / Ensure Running ──────────────────────────────────

runtime_ensure_started() {
    kine_step "Starting Android runtime"

    # Start the Waydroid container (system service)
    if ! systemctl is-active --quiet waydroid-container 2>/dev/null; then
        kine_dim "Starting waydroid-container service..."
        sudo systemctl start waydroid-container 2>/dev/null || {
            kine_warn "systemctl failed — trying manual container start..."
            sudo waydroid container start &>/dev/null &
            sleep 3
        }
    else
        kine_dim "waydroid-container service already active"
    fi

    # Start the Waydroid session UI (user session)
    local display_backend
    display_backend=$(load_display_config && echo "${DISPLAY_BACKEND:-auto}" || echo "auto")

    kine_dim "Starting Waydroid session (backend: ${display_backend})..."

    # Start session in background, suppress console UI
    waydroid session start &>/dev/null &
    local session_pid=$!

    # Wait for session to be ready (up to 30s)
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if waydroid status 2>/dev/null | grep -q "Session Running"; then
            kine_success "Android session is running"
            return 0
        fi
        sleep 1
        (( waited++ ))
        printf "\r  ${C_CYAN}⠋${C_RESET}  Waiting for session... (${waited}s)"
    done

    printf "\n"

    # Check if it started despite timeout
    if waydroid status 2>/dev/null | grep -q "Session Running\|RUNNING"; then
        kine_success "Android session is running"
        return 0
    fi

    kine_warn "Session startup timeout — attempting display fix"
    fix_display_error "session start timeout"

    # One more try after display fix
    waydroid session stop &>/dev/null 2>&1 || true
    sleep 1
    waydroid session start &>/dev/null &
    sleep 5

    if waydroid status 2>/dev/null | grep -q "Session Running\|RUNNING"; then
        kine_success "Android session is running (after display fix)"
    else
        kine_warn "Session may not be fully ready — launch will retry automatically"
    fi
}

# ─── Stop ────────────────────────────────────────────────────

runtime_stop() {
    kine_step "Stopping Kine runtime"

    waydroid session stop &>/dev/null 2>&1 || true
    sudo systemctl stop waydroid-container &>/dev/null 2>&1 || {
        sudo waydroid container stop &>/dev/null 2>&1 || true
    }

    kine_success "Runtime stopped"
}

# ─── Status ──────────────────────────────────────────────────

runtime_status() {
    kine_header "Kine Status"

    # Runtime init status
    if check_runtime_initialized; then
        kine_success "Runtime: Initialized"
        if [[ -f "${KINE_RUNTIME_CONFIG}" ]]; then
            local model channel init_date
            model=$(grep "^MODEL=" "${KINE_RUNTIME_CONFIG}" | cut -d= -f2)
            channel=$(grep "^CHANNEL=" "${KINE_RUNTIME_CONFIG}" | cut -d= -f2)
            init_date=$(grep "^INIT_DATE=" "${KINE_RUNTIME_CONFIG}" | cut -d= -f2-)
            kine_dim "  Model:       ${model}"
            kine_dim "  Channel:     ${channel}"
            kine_dim "  Init date:   ${init_date}"
        fi
    else
        kine_warn "Runtime: Not initialized (run: kine init <model>)"
    fi

    kine_divider

    # Waydroid status
    kine_info "Waydroid container:"
    if systemctl is-active --quiet waydroid-container 2>/dev/null; then
        kine_success "  Container service: Active"
    else
        kine_warn "  Container service: Inactive"
    fi

    local wd_status
    wd_status=$(waydroid status 2>/dev/null || echo "Not running")
    if echo "$wd_status" | grep -q "Session Running"; then
        kine_success "  Session: Running"
    else
        kine_warn "  Session: Not running"
    fi

    kine_divider

    # Display info
    kine_info "Display:"
    if [[ -f "${KINE_DISPLAY_CONFIG}" ]]; then
        source "${KINE_DISPLAY_CONFIG}" 2>/dev/null || true
        kine_dim "  Backend:  ${DISPLAY_BACKEND:-unknown}"
        kine_dim "  GPU mode: ${GPU_MODE:-unknown}"
        [[ -n "${WAYLAND_DISPLAY:-}" ]] && kine_dim "  Wayland:  ${WAYLAND_DISPLAY}"
        [[ -n "${DISPLAY:-}" ]] && kine_dim "  X11:      ${DISPLAY}"
    else
        kine_dim "  Display not configured (run: kine init)"
    fi

    kine_divider

    # Installed apps
    kine_info "Installed apps:"
    local apps_dir="${KINE_HOME}/apps"
    if [[ -d "$apps_dir" ]] && [[ -n "$(ls -A "$apps_dir" 2>/dev/null)" ]]; then
        for apk in "${apps_dir}"/*.apk; do
            [[ -f "$apk" ]] && kine_dim "  $(basename "$apk")"
        done
    else
        kine_dim "  No apps installed"
    fi

    kine_divider
}

# ─── Command Implementations ─────────────────────────────────

cmd_init() {
    local model="$1"
    require_deps
    runtime_init "$model"
}

cmd_stop() {
    require_waydroid
    runtime_stop
}

cmd_status() {
    runtime_status
}

cmd_logs() {
    local log_file="${KINE_HOME}/logs/kine.log"
    if [[ -f "$log_file" ]]; then
        tail -f "$log_file"
    else
        kine_warn "No log file found at ${log_file}"
        kine_info "Logs are created when you first run kine commands"
    fi
}
