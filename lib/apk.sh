#!/usr/bin/env bash
# ─── Kine APK Library ────────────────────────────────────────
# Handles APK validation, installation, and launching

KINE_APPS_DIR="${KINE_HOME}/apps"
KINE_CACHE_DIR="${KINE_HOME}/cache"

# ─── APK Validation ──────────────────────────────────────────

validate_apk() {
    local apk_path="$1"

    # Check file exists
    if [[ ! -f "$apk_path" ]]; then
        kine_error "APK not found: ${apk_path}"
        return 1
    fi

    # Check file extension
    if [[ "${apk_path,,}" != *.apk ]]; then
        kine_warn "File does not have .apk extension: ${apk_path}"
        kine_info "Proceeding anyway..."
    fi

    # Check APK magic bytes (ZIP header: PK\x03\x04)
    local magic
    magic=$(xxd -l 4 -p "$apk_path" 2>/dev/null || od -A n -N 4 -t x1 "$apk_path" 2>/dev/null | tr -d ' \n')

    if [[ "$magic" != "504b0304"* ]] && [[ "$magic" != "504b 0304"* ]]; then
        kine_error "Invalid APK file (not a valid ZIP/APK archive)"
        kine_info  "The file may be corrupted or not an Android application"
        return 1
    fi

    kine_success "APK file is valid: $(basename "$apk_path")"
    return 0
}

# Extract package name from APK using aapt or aapt2
get_package_name() {
    local apk_path="$1"
    local pkg_name=""

    if command -v aapt2 &>/dev/null; then
        pkg_name=$(aapt2 dump packagename "$apk_path" 2>/dev/null)
    elif command -v aapt &>/dev/null; then
        pkg_name=$(aapt dump badging "$apk_path" 2>/dev/null | grep "^package:" | sed "s/.*name='\([^']*\)'.*/\1/")
    fi

    # Fallback: try to get from AndroidManifest via unzip
    if [[ -z "$pkg_name" ]]; then
        if command -v apktool &>/dev/null; then
            local tmpdir
            tmpdir=$(mktemp -d)
            apktool d -f -o "$tmpdir" "$apk_path" &>/dev/null && \
                pkg_name=$(grep 'package=' "${tmpdir}/AndroidManifest.xml" 2>/dev/null | sed 's/.*package="\([^"]*\)".*/\1/' | head -1)
            rm -rf "$tmpdir"
        fi
    fi

    echo "$pkg_name"
}

# ─── Ensure Session Active ───────────────────────────────────

ensure_session() {
    local max_tries=3
    local try=0

    while [[ $try -lt $max_tries ]]; do
        if waydroid status 2>/dev/null | grep -q "Session Running"; then
            return 0
        fi

        (( try++ ))
        kine_info "Waiting for Android session (attempt ${try}/${max_tries})..."

        if [[ $try -eq 1 ]]; then
            # Try loading display config and restarting session
            load_display_config 2>/dev/null || true
            waydroid session start &>/dev/null &
            sleep 5
        elif [[ $try -eq 2 ]]; then
            # Try display fix
            fix_display_error "session not available"
            waydroid session stop &>/dev/null 2>&1 || true
            sleep 2
            waydroid session start &>/dev/null &
            sleep 8
        else
            # Last resort: restart container
            kine_warn "Restarting container..."
            sudo systemctl restart waydroid-container &>/dev/null 2>&1 || true
            sleep 5
            waydroid session start &>/dev/null &
            sleep 8
        fi
    done

    if waydroid status 2>/dev/null | grep -q "Session Running\|RUNNING"; then
        return 0
    fi

    kine_error "Android session could not be started"
    kine_info  "Try manually: waydroid session start"
    kine_info  "Check logs:   ~/.kine/logs/kine.log"
    return 1
}

# ─── Install APK ─────────────────────────────────────────────

install_apk() {
    local apk_path="$1"
    local apk_abs
    apk_abs="$(realpath "$apk_path")"

    kine_step "Installing APK: $(basename "$apk_abs")"

    # Validate APK
    validate_apk "$apk_abs" || return 1

    # Ensure session is running
    ensure_session || return 1

    # Copy to kine apps dir for tracking
    mkdir -p "${KINE_APPS_DIR}"
    cp "$apk_abs" "${KINE_APPS_DIR}/" 2>/dev/null || true

    # Install via Waydroid
    kine_info "Installing into Android runtime..."
    if waydroid app install "$apk_abs" 2>&1 | tee -a "${KINE_HOME}/logs/kine.log" | grep -v "^$"; then
        kine_success "APK installed: $(basename "$apk_abs")"
        return 0
    else
        kine_error "APK installation failed"
        kine_info  "Check: ~/.kine/logs/kine.log"
        return 1
    fi
}

# ─── Launch APK ──────────────────────────────────────────────

launch_apk() {
    local apk_path="$1"
    local apk_abs
    apk_abs="$(realpath "$apk_path")"

    kine_header "Launching APK"
    kine_info "App: $(basename "$apk_abs")"

    # Validate APK
    validate_apk "$apk_abs" || return 1

    # Check runtime initialized
    if ! check_runtime_initialized; then
        kine_error "Kine runtime not initialized"
        kine_info  "Run: kine init <model>   (e.g. kine init pixel5)"
        return 1
    fi

    # Load display settings
    if load_display_config; then
        kine_dim "Display backend: ${DISPLAY_BACKEND:-auto}"
    else
        kine_warn "No display config found — auto-detecting..."
        setup_display auto
    fi

    # Ensure Waydroid session is active
    kine_step "Starting Android session"
    ensure_session || return 1

    # Get or determine package name
    local pkg_name
    pkg_name=$(get_package_name "$apk_abs")

    # Check if already installed in Waydroid
    local already_installed=false
    if [[ -n "$pkg_name" ]]; then
        if waydroid app list 2>/dev/null | grep -q "$pkg_name"; then
            kine_info "App already installed (${pkg_name})"
            already_installed=true
        fi
    fi

    # Install if needed
    if [[ "$already_installed" == false ]]; then
        kine_step "Installing APK"
        install_apk "$apk_abs" || return 1
        sleep 2  # Allow Android to register the app
    fi

    # Launch the app
    kine_step "Launching application"

    if [[ -n "$pkg_name" ]]; then
        kine_dim "Package: ${pkg_name}"
        # Launch without showing emulator dashboard
        if waydroid app launch "$pkg_name" &>/dev/null 2>&1; then
            kine_success "App launched: ${pkg_name}"
            kine_info   "The app is running in its own window"
            kine_dim    "Press Ctrl+C here or close the window to stop"
        else
            kine_warn "Direct launch failed — retrying with display fix..."
            fix_display_error "app launch failed"
            sleep 2
            if waydroid app launch "$pkg_name" 2>&1 | tee -a "${KINE_HOME}/logs/kine.log"; then
                kine_success "App launched (after fix)"
            else
                kine_error "Failed to launch app"
                kine_info  "Package: ${pkg_name}"
                kine_info  "Try manually: waydroid app launch ${pkg_name}"
                return 1
            fi
        fi
    else
        kine_warn "Could not determine package name from APK"
        kine_info "Attempting install-and-launch via Waydroid..."
        waydroid app install "$apk_abs" 2>&1 | tee -a "${KINE_HOME}/logs/kine.log"

        kine_info "Please launch the app from the Android home screen"
        kine_dim  "(Package name could not be determined — install aapt for auto-launch)"
        kine_info "Run: sudo apt install aapt"
    fi
}

# ─── Command Implementations ─────────────────────────────────

cmd_launch() {
    local apk_path="$1"
    require_waydroid
    launch_apk "$apk_path"
}

cmd_install() {
    local apk_path="$1"
    require_waydroid
    install_apk "$apk_path"
}
