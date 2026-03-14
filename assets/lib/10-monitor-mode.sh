#!/bin/bash
# BJORN Installer - Wi-Fi Monitor Mode Patch (Nexmon)
# Sourced by install_bjorn.sh (requires 00-common.sh, 01-platform.sh)

install_monitor_mode() {
    log "INFO" "Checking if Wi-Fi Monitor Mode patch is needed..."

    # Target the Pi Zero 2 W and Pi 3 that share this Wi-Fi chipset family.
    if [[ "$PI_MODEL" == *"Zero 2"* ]] || [[ "$PI_MODEL" == *"Pi 3"* ]]; then
        log "INFO" "Compatible board detected for Nexmon patch: $PI_MODEL"

        local TEMP_REPO="/tmp/infinition_repo_temp"
        local FIRMWARE_SRC=""
        local BACKUP_DIR=""
        local PATCH_CACHE_DIR="/home/$BJORN_USER/.settings_bjorn/monitor_mode_patch"
        local DEFAULT_ROUTE_IFACE=""

        if [ "$ARCH" = "arm64" ]; then
            log "WARNING" "64-bit OS detected (${ARCH}). Monitor mode on this chipset may remain limited or unstable even with the firmware patch."
            echo -e "${YELLOW}64-bit OS detected (${ARCH}). The Nexmon firmware patch will be installed and cached, but monitor mode compatibility can still depend on the kernel/userspace stack.${NC}"
        fi

        log "INFO" "Downloading patched firmwares from GitHub..."
        rm -rf "$TEMP_REPO"

        if git clone --depth 1 https://github.com/infinition/infinition.git "$TEMP_REPO" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Downloaded firmware patches from GitHub"
        else
            log "ERROR" "Failed to download firmware patches"
            failed_apt_packages+=("Download Nexmon firmware")
            return 0
        fi

        FIRMWARE_SRC="$TEMP_REPO/fixes/bjorn/monitor"
        if [ ! -d "$FIRMWARE_SRC" ]; then
            log "ERROR" "Firmware patch directory not found in cloned repository: $FIRMWARE_SRC"
            failed_apt_packages+=("Locate Nexmon firmware")
            rm -rf "$TEMP_REPO"
            return 0
        fi

        log "INFO" "Backing up original firmware..."
        BACKUP_DIR="/home/$BJORN_USER/.backups_bjorn/original_firmware_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp -r /lib/firmware/brcm "$BACKUP_DIR/" 2>/dev/null
        cp -r /lib/firmware/cypress "$BACKUP_DIR/" 2>/dev/null
        log "SUCCESS" "Original firmware backed up to $BACKUP_DIR"

        log "INFO" "Applying Nexmon monitor mode patches to /lib/firmware..."
        if [ -d "$FIRMWARE_SRC/brcm" ]; then
            cp -rf "$FIRMWARE_SRC/brcm/"* /lib/firmware/brcm/ >> "$LOG_FILE" 2>&1
        fi
        if [ -d "$FIRMWARE_SRC/cypress" ]; then
            cp -rf "$FIRMWARE_SRC/cypress/"* /lib/firmware/cypress/ >> "$LOG_FILE" 2>&1
        fi
        log "SUCCESS" "Nexmon firmware applied successfully"

        log "INFO" "Caching monitor mode firmware patch locally..."
        mkdir -p "$PATCH_CACHE_DIR"
        rm -rf "$PATCH_CACHE_DIR/brcm" "$PATCH_CACHE_DIR/cypress"
        if [ -d "$FIRMWARE_SRC/brcm" ]; then
            cp -rf "$FIRMWARE_SRC/brcm" "$PATCH_CACHE_DIR/" >> "$LOG_FILE" 2>&1
        fi
        if [ -d "$FIRMWARE_SRC/cypress" ]; then
            cp -rf "$FIRMWARE_SRC/cypress" "$PATCH_CACHE_DIR/" >> "$LOG_FILE" 2>&1
        fi
        chown -R "$BJORN_USER:$BJORN_USER" "$PATCH_CACHE_DIR" >> "$LOG_FILE" 2>&1 || true
        log "SUCCESS" "Cached monitor mode firmware patch in $PATCH_CACHE_DIR"

        log "INFO" "Holding kernel and firmware packages to prevent overwrite..."
        if apt-mark hold firmware-brcm80211 raspberrypi-kernel raspberrypi-bootloader >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Packages held successfully. Monitor mode is secured."
        else
            log "WARNING" "Failed to hold packages. apt upgrade might break monitor mode."
        fi

        log "INFO" "Reloading brcmfmac modules..."
        DEFAULT_ROUTE_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
        if [[ "$DEFAULT_ROUTE_IFACE" == wl* ]]; then
            log "WARNING" "Skipping live brcmfmac reload because the active default route uses $DEFAULT_ROUTE_IFACE"
            echo -e "${YELLOW}Wi-Fi firmware patch applied, but live reload was skipped to avoid cutting the current SSH session on ${DEFAULT_ROUTE_IFACE}.${NC}"
            echo -e "${YELLOW}Reboot the device to activate the monitor mode firmware safely.${NC}"
        else
            rmmod brcmfmac_wcc 2>/dev/null
            modprobe -r brcmfmac 2>/dev/null
            modprobe brcmfmac 2>/dev/null
        fi

        rm -rf "$TEMP_REPO"
        log "SUCCESS" "Wi-Fi Monitor mode patch installation completed"
    else
        log "INFO" "Not a Pi Zero 2 W or Pi 3 ($PI_MODEL). Skipping custom Nexmon patch."
    fi
}
