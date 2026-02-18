#!/bin/bash
# BJORN Installer — Platform detection & compatibility checks
# Sourced by install_bjorn.sh (requires 00-common.sh)

# Platform fact variables (filled at runtime by detect_platform)
OS_NAME=""
OS_PRETTY=""
OS_VERSION_ID=""
OS_CODENAME=""
ARCH=""
IS_RPI=0
PI_MODEL=""
HAS_NM=0
PIP_BREAK_FLAG="--break-system-packages"
KERNEL_M=""
IS_ARMV6=0

detect_platform() {
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "")
    if [ -f "/etc/os-release" ]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_NAME="$NAME"
        OS_PRETTY="$PRETTY_NAME"
        OS_VERSION_ID="$VERSION_ID"
        OS_CODENAME="${VERSION_CODENAME:-}"
    fi
    if [ -f "/proc/device-tree/model" ]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
        [[ "$PI_MODEL" == *"Raspberry Pi"* ]] && IS_RPI=1 || IS_RPI=0
    fi
    if command -v nmcli >/dev/null 2>&1 || systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
        HAS_NM=1
    else
        HAS_NM=0
    fi

    # Detect kernel machine for armv6
    KERNEL_M=$(uname -m 2>/dev/null || echo "")
    IS_ARMV6=0
    [ "$KERNEL_M" = "armv6l" ] && IS_ARMV6=1

    # pip3 flag: always force; a fallback will retry without it if unsupported
    PIP_BREAK_FLAG="--break-system-packages"
    log "INFO" "pip3 will be called with: $PIP_BREAK_FLAG (with fallback if unsupported)"

    log "INFO" "Platform: arch=${ARCH} os='${OS_NAME}' (${OS_PRETTY}) codename='${OS_CODENAME}'"
    [ "$IS_RPI" -eq 1 ] && log "INFO" "Raspberry Pi detected: ${PI_MODEL}" || log "INFO" "Non-Raspberry hardware"
    [ "$HAS_NM" -eq 1 ] && log "INFO" "NetworkManager detected" || log "INFO" "NetworkManager not detected"
    [ "$IS_ARMV6" -eq 1 ] && log "INFO" "Detected armv6 (Raspberry Pi Zero 1 class)"
}

# Boot file path detection (Bookworm uses /boot/firmware)
detect_boot_paths() {
    local cmd1a="/boot/firmware/cmdline.txt"
    local cmd1b="/boot/cmdline.txt"
    local cfg1a="/boot/firmware/config.txt"
    local cfg1b="/boot/config.txt"
    if [ -f "$cmd1a" ]; then
        echo "$cmd1a|$cfg1a"
    else
        echo "$cmd1b|$cfg1b"
    fi
}

# Check system compatibility (extended to support Debian too)
check_system_compatibility() {
    log "INFO" "Checking system compatibility..."
    local should_ask_confirmation=false

    detect_platform

    # 1. Detect Raspberry Pi Model
    if [ "$IS_RPI" -eq 1 ]; then
        log "SUCCESS" "Raspberry Pi model detected: ${PI_MODEL}"
    else
        log "WARNING" "Different hardware model detected."
        echo -e "${YELLOW}This script is primarily designed for Raspberry Pi hardware.${NC}"
        should_ask_confirmation=true
    fi

    # 2. RAM check
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_ram" -lt 410 ]; then
        log "WARNING" "Low RAM detected. Recommended >= 512MB (410MB with OS running), Found: ${total_ram}MB"
        echo -e "${YELLOW}System RAM is below the recommendation; continuing may be slower.${NC}"
        should_ask_confirmation=true
    else
        log "SUCCESS" "RAM check passed: ${total_ram}MB available"
    fi

    # 3. Disk space
    available_space=$(df -m /home | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 4096 ]; then
        log "WARNING" "Low disk space. Recommended: 4GB, Found: ${available_space}MB"
        echo -e "${YELLOW}Free space below 4GB; installation may be impacted.${NC}"
        should_ask_confirmation=true
    else
        log "SUCCESS" "Disk space check passed: ${available_space}MB available"
    fi

    # 4. OS check (accept Raspberry Pi OS or Debian)
    if [ -n "$OS_NAME" ]; then
        if [[ "$OS_NAME" != "Raspbian GNU/Linux" && "$OS_NAME" != "Raspberry Pi OS" && "$OS_NAME" != "Debian GNU/Linux" ]]; then
            log "WARNING" "Different OS detected: ${OS_PRETTY}"
            echo -e "${YELLOW}This script was tested on Raspberry Pi OS / Debian. Detected: ${OS_PRETTY}.${NC}"
            should_ask_confirmation=true
        fi
        # Version advisory
        expected_version="13"
        if [[ -n "$OS_VERSION_ID" && "$OS_VERSION_ID" != "$expected_version" ]]; then
            log "WARNING" "OS version differs from tested baseline (12/Bookworm). Detected: ${OS_VERSION_ID} (${OS_CODENAME})"
            echo -e "${YELLOW}Tested baseline is version 12 (Bookworm). Detected: ${OS_PRETTY}.${NC}"
            should_ask_confirmation=true
        else
            log "SUCCESS" "OS version advisory: ${OS_PRETTY}"
        fi
    else
        log "WARNING" "Could not determine OS version (/etc/os-release missing)"
        should_ask_confirmation=true
    fi

    # 5. Architecture check
    if [[ "$ARCH" != "armhf" && "$ARCH" != "arm64" ]]; then
        log "WARNING" "Non-arm architecture detected (${ARCH}). Script is optimized for armhf/arm64."
        echo -e "${YELLOW}Script is optimized for armhf/arm64.${NC}"
        should_ask_confirmation=true
    else
        log "SUCCESS" "Architecture check passed: ${ARCH}"
    fi

    # 6. Confirm if warnings (skip in non-interactive mode)
    if [ "$should_ask_confirmation" = true ]; then
        if [ "$NON_INTERACTIVE" = "1" ]; then
            log "INFO" "Non-interactive mode: auto-accepting compatibility warnings"
        else
            echo -e "\n${YELLOW}Some compatibility warnings were detected (see log). Continue anyway? (y/n)${NC}"
            read -r response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                log "INFO" "Installation aborted by user after compatibility warnings"
                clean_exit 1
            fi
        fi
    else
        log "SUCCESS" "All compatibility checks passed"
    fi

    log "INFO" "System compatibility check completed"
    return 0
}
