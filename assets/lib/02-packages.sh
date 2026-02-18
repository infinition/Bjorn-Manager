#!/bin/bash
# BJORN Installer — Package management (APT + PIP)
# Sourced by install_bjorn.sh (requires 00-common.sh, 01-platform.sh)

# Safe apt install with optional fallback
apt_install_safe() {
    # usage: apt_install_safe pkg [fallback_pkg]
    local pkg="$1"
    local fallback="$2"
    log "INFO" "Installing $pkg..."
    if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Installed $pkg"
        return 0
    fi
    if [ -n "$fallback" ]; then
        log "WARNING" "Failed to install $pkg, trying fallback $fallback"
        if apt-get install -y "$fallback" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Installed fallback $fallback (for $pkg)"
            return 0
        fi
    fi
    log "ERROR" "Failed to install $pkg"
    failed_apt_packages+=("$pkg")
    return 1
}

# Prefer piwheels on Raspberry/ARM; harmless elsewhere
ensure_piwheels() {
    if ! grep -q "piwheels.org/simple" /etc/pip.conf 2>/dev/null; then
        {
            echo "[global]"
            echo "extra-index-url = https://www.piwheels.org/simple"
        } >> /etc/pip.conf
        log "SUCCESS" "Enabled piwheels in /etc/pip.conf"
    else
        log "INFO" "piwheels already configured"
    fi
}

# Always try with --break-system-packages; if unsupported, retry without (non-fatal)
pip_install() {
    # usage: pip_install [extra pip args...] <pkg-or-req>
    if pip3 install $PIP_BREAK_FLAG "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    fi
    log "WARNING" "pip3 install failed with $PIP_BREAK_FLAG; retrying without it"
    if pip3 install "$@" >> "$LOG_FILE" 2>&1; then
        return 0
    fi
    return 1
}

# Avoid heavy builds on armv6 by taking crypto/numpy from APT
install_python_stack_zero1() {
    log "INFO" "armv6 detected → installing Python crypto/scientific stack via APT"
    apt-get update >> "$LOG_FILE" 2>&1 || true
    apt_install_safe "python3-paramiko" || true
    apt_install_safe "python3-cryptography" || true
    apt_install_safe "python3-bcrypt" || true
    apt_install_safe "python3-nacl" || true
    apt_install_safe "python3-numpy" || true
    export BJORN_ZERO1_APT_CRYPTO=1
}

# Install system dependencies (adaptive, resilient)
install_dependencies() {
    log "INFO" "Installing system dependencies..."

    # Detect current architecture
    CURRENT_ARCH="$ARCH"
    [ -z "$CURRENT_ARCH" ] && CURRENT_ARCH=$(dpkg --print-architecture)
    log "INFO" "Detected architecture: $CURRENT_ARCH"

    # Prefer piwheels for faster, wheel-first installs
    ensure_piwheels

    # Base required packages (keep content, adapt around conflicts)
    packages=(
        "python3-pip"
        "python3-psutil"
        "wget"
        "lsof"
        "git"
        "libopenjp2-7"
        "nmap"
        "libopenblas-dev"
        "bluez-tools"
        "bluez"
        "dhcpcd5"
        "dnsmasq"
        "python3-dbus"
        "bridge-utils"
        "python3-pil"
        "libjpeg-dev"
        "zlib1g-dev"
        "libpng-dev"
        "python3-dev"
        "libffi-dev"
        "libssl-dev"
        "libgpiod-dev"
        "libi2c-dev"
        "libssl1.1"
        "libatlas-base-dev"
        "build-essential"
        "gobuster"
        "arping"
        "arp-scan"
    )

    # Skip dhcpcd5 when NetworkManager is present (to avoid conflicts)
    if [ "$HAS_NM" -eq 1 ]; then
        log "INFO" "NetworkManager detected; skipping dhcpcd5 install to avoid conflicts"
        packages=("${packages[@]/dhcpcd5}")
    fi

    case $INSTALL_MODE in
        "local")
            log "INFO" "Using local packages from: $PACKAGES_PATH"
            ARCH_PATH="${PACKAGES_PATH}/${CURRENT_ARCH}/apt"
            if [ ! -d "$ARCH_PATH" ]; then
                log "ERROR" "Local APT package directory for $CURRENT_ARCH not found at $ARCH_PATH"
                # Do not abort; fall back to online mode for resilience
                log "WARNING" "Falling back to online mode for APT dependencies"
                INSTALL_MODE="online"
            else
                # Install all .deb found for this arch
                log "INFO" "Installing local .deb packages for $CURRENT_ARCH"
                shopt -s nullglob
                local had_any=0
                for pkg in "$ARCH_PATH"/*.deb; do
                    had_any=1
                    log "INFO" "Installing local package: $(basename "$pkg")"
                    if dpkg -i "$pkg" >> "$LOG_FILE" 2>&1; then
                        log "SUCCESS" "Installed $(basename "$pkg")"
                    else
                        log "ERROR" "Failed to install $(basename "$pkg")"
                        failed_apt_packages+=("$(basename "$pkg")")
                    fi
                done
                shopt -u nullglob
                if [ "$had_any" -eq 0 ]; then
                    log "WARNING" "No .deb files found in $ARCH_PATH; leaving APT phase to online mode"
                    INSTALL_MODE="online"
                fi

                # Fix any broken deps (non-fatal)
                if ! apt-get install -f -y >> "$LOG_FILE" 2>&1; then
                    log "ERROR" "Failed to fix dependencies after local install"
                    failed_apt_packages+=("dependencies fix after local dpkg -i")
                else
                    log "SUCCESS" "Fixed dependencies after local install"
                fi
            fi
            ;;&  # fall-through to possibly run online if we switched mode

        "online")
            # Update package list (non-fatal on failure)
            if apt-get update >> "$LOG_FILE" 2>&1; then
                log "SUCCESS" "Package list updated successfully"
            else
                log "ERROR" "Failed to update package list (continuing)"
                failed_apt_packages+=("apt-get update")
            fi

            # Install packages with smart fallbacks
            for package in "${packages[@]}"; do
                case "$package" in
                    libssl1.1)
                        # Try libssl1.1; if not available, fallback to libssl3
                        apt_install_safe "libssl1.1" "libssl3" || true
                        ;;
                    bluez-tools)
                        # Some images might not have bluez-tools; it's optional
                        apt_install_safe "bluez-tools" || true
                        ;;
                    dnsmasq)
                        apt_install_safe "dnsmasq" || true
                        ;;
                    *)
                        apt_install_safe "$package" || true
                        ;;
                esac
            done

            # Update nmap scripts (non-fatal)
            if nmap --script-updatedb >> "$LOG_FILE" 2>&1; then
                log "SUCCESS" "nmap scripts updated successfully"
            else
                log "ERROR" "Failed to update nmap scripts"
                failed_apt_packages+=("nmap --script-updatedb")
            fi
            ;;
        *)
            log "ERROR" "Invalid installation mode: $INSTALL_MODE"
            # Do not abort the whole run; just record for recap
            failed_apt_packages+=("invalid INSTALL_MODE=$INSTALL_MODE")
            ;;
    esac

    # On Zero 1 (armv6), install crypto/scientific libs from APT to avoid heavy pip builds
    if [ "$IS_ARMV6" -eq 1 ]; then
        install_python_stack_zero1
    fi

    log "INFO" "Dependencies installation completed"
}
