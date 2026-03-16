#!/bin/bash
# BJORN Installer - Wi-Fi Monitor Mode (Safe Firmware Switcher)
# Sourced by install_bjorn.sh (requires 00-common.sh, 01-platform.sh)
#
# Architecture:
#   - brcmfmac is BLACKLISTED at boot (prevents crash with patched firmware)
#   - usb-gadget.service starts first → RNDIS always works
#   - bluetooth.service starts → BT PAN tethering always works
#   - bjorn-wifi.service restores stock firmware, then loads brcmfmac safely
#   - bjorn-monitor-mode script hot-swaps firmware on demand
#
# Boot order: kernel → [brcmfmac blocked] → usb-gadget → bluetooth → bjorn-wifi → bjorn

install_monitor_mode() {
    log "INFO" "Checking if Wi-Fi Monitor Mode patch is needed..."

    # Target the Pi Zero 2 W and Pi 3 that share this Wi-Fi chipset family.
    if [[ "$PI_MODEL" == *"Zero 2"* ]] || [[ "$PI_MODEL" == *"Pi 3"* ]]; then
        log "INFO" "Compatible board detected for Nexmon patch: $PI_MODEL"

        local TEMP_REPO="/tmp/infinition_repo_temp"
        local FIRMWARE_SRC=""
        local STOCK_DIR="/home/$BJORN_USER/.settings_bjorn/firmware_stock"
        local PATCHED_DIR="/home/$BJORN_USER/.settings_bjorn/firmware_patched"
        local BACKUP_DIR=""

        if [ "$ARCH" = "arm64" ]; then
            log "WARNING" "64-bit OS detected (${ARCH}). Monitor mode on this chipset may remain limited or unstable even with the firmware patch."
            echo -e "${YELLOW}64-bit OS detected (${ARCH}). The Nexmon firmware patch will be cached but NOT applied to live firmware.${NC}"
            echo -e "${YELLOW}Use 'bjorn monitor on' to activate monitor mode on demand.${NC}"
        fi

        # ── Step 1: Cache stock firmware (BEFORE any changes) ──────────
        log "INFO" "Caching stock (original) firmware..."
        mkdir -p "$STOCK_DIR"
        rm -rf "$STOCK_DIR/brcm" "$STOCK_DIR/cypress"
        cp -r /lib/firmware/brcm "$STOCK_DIR/" 2>/dev/null
        cp -r /lib/firmware/cypress "$STOCK_DIR/" 2>/dev/null
        chown -R "$BJORN_USER:$BJORN_USER" "$STOCK_DIR" >> "$LOG_FILE" 2>&1 || true
        log "SUCCESS" "Stock firmware cached in $STOCK_DIR"

        # Also keep a timestamped backup in .backups_bjorn/
        BACKUP_DIR="/home/$BJORN_USER/.backups_bjorn/original_firmware_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp -r /lib/firmware/brcm "$BACKUP_DIR/" 2>/dev/null
        cp -r /lib/firmware/cypress "$BACKUP_DIR/" 2>/dev/null
        log "SUCCESS" "Original firmware backed up to $BACKUP_DIR"

        # ── Step 2: Download and cache patched (Nexmon) firmware ───────
        log "INFO" "Downloading patched firmwares from GitHub..."
        rm -rf "$TEMP_REPO"

        if git clone --depth 1 https://github.com/infinition/infinition.git "$TEMP_REPO" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Downloaded firmware patches from GitHub"
        else
            log "ERROR" "Failed to download firmware patches"
            failed_apt_packages+=("Download Nexmon firmware")
            rm -rf "$TEMP_REPO"
            # Continue — stock firmware still works, monitor mode just won't be available
            _install_monitor_mode_services
            return 0
        fi

        FIRMWARE_SRC="$TEMP_REPO/fixes/bjorn/monitor"
        if [ ! -d "$FIRMWARE_SRC" ]; then
            log "ERROR" "Firmware patch directory not found in cloned repository: $FIRMWARE_SRC"
            failed_apt_packages+=("Locate Nexmon firmware")
            rm -rf "$TEMP_REPO"
            _install_monitor_mode_services
            return 0
        fi

        log "INFO" "Caching patched firmware locally..."
        mkdir -p "$PATCHED_DIR"
        rm -rf "$PATCHED_DIR/brcm" "$PATCHED_DIR/cypress"
        if [ -d "$FIRMWARE_SRC/brcm" ]; then
            cp -rf "$FIRMWARE_SRC/brcm" "$PATCHED_DIR/" >> "$LOG_FILE" 2>&1
        fi
        if [ -d "$FIRMWARE_SRC/cypress" ]; then
            cp -rf "$FIRMWARE_SRC/cypress" "$PATCHED_DIR/" >> "$LOG_FILE" 2>&1
        fi
        chown -R "$BJORN_USER:$BJORN_USER" "$PATCHED_DIR" >> "$LOG_FILE" 2>&1 || true
        log "SUCCESS" "Patched firmware cached in $PATCHED_DIR"

        rm -rf "$TEMP_REPO"

        # ── Step 3: DO NOT apply patched firmware to /lib/firmware/ ────
        # Stock firmware stays in place. Patched firmware is only used
        # on-demand via 'bjorn monitor on'.
        log "INFO" "Stock firmware left in place (patched firmware cached for on-demand use)"

        # ── Step 4: Hold packages to prevent apt from touching firmware ─
        log "INFO" "Holding kernel and firmware packages to prevent overwrite..."
        if apt-mark hold firmware-brcm80211 raspberrypi-kernel raspberrypi-bootloader >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Packages held successfully"
        else
            log "WARNING" "Failed to hold packages. apt upgrade might overwrite firmware."
        fi

        # ── Step 5: Install services and scripts ──────────────────────
        _install_monitor_mode_services

        log "SUCCESS" "Wi-Fi Monitor mode setup completed (stock firmware active, patched cached)"
        echo -e "${GREEN}Monitor mode is ready. Use 'bjorn monitor on' to activate.${NC}"
        echo -e "${GREEN}RNDIS and Bluetooth are always available, regardless of WiFi mode.${NC}"
    else
        log "INFO" "Not a Pi Zero 2 W or Pi 3 ($PI_MODEL). Skipping custom Nexmon patch."
    fi
}

_install_monitor_mode_services() {
    # ── Blacklist brcmfmac at boot ─────────────────────────────────
    log "INFO" "Blacklisting brcmfmac at boot (will be loaded by bjorn-wifi.service)..."
    cat > /etc/modprobe.d/bjorn-wifi-defer.conf << 'MODEOF'
# BJORN: Defer brcmfmac loading to prevent crash with patched firmware at boot.
# brcmfmac is loaded explicitly by bjorn-wifi.service AFTER usb-gadget is ready.
# This ensures RNDIS and Bluetooth always work, regardless of WiFi firmware state.
blacklist brcmfmac
blacklist brcmfmac_wcc
MODEOF
    log "SUCCESS" "brcmfmac blacklisted at boot"

    # ── Install /usr/local/bin/bjorn-monitor-mode ──────────────────
    log "INFO" "Installing bjorn-monitor-mode firmware switcher script..."
    cat > /usr/local/bin/bjorn-monitor-mode << 'SCRIPTEOF'
#!/bin/bash
# bjorn-monitor-mode — firmware hot-swap for WiFi monitor mode
# RNDIS (dwc2+libcomposite) and Bluetooth (hci0) are completely
# independent and NEVER affected by this script.
#
# Usage:
#   bjorn-monitor-mode on       Swap to patched firmware, enable monitor mode
#   bjorn-monitor-mode off      Restore stock firmware, reconnect WiFi
#   bjorn-monitor-mode status   Show current mode
#   bjorn-monitor-mode restore  Silent restore stock (used at boot)
#   bjorn-monitor-mode load     Load brcmfmac with stock firmware (used at boot)

set -euo pipefail

BJORN_USER="bjorn"
STOCK_DIR="/home/$BJORN_USER/.settings_bjorn/firmware_stock"
PATCHED_DIR="/home/$BJORN_USER/.settings_bjorn/firmware_patched"
FW_BRCM="/lib/firmware/brcm"
FW_CYPRESS="/lib/firmware/cypress"
STATE_FILE="/tmp/.bjorn_monitor_mode"

ensure_stock() {
    if [ ! -d "$STOCK_DIR/brcm" ]; then
        echo "ERROR: No stock firmware cache at $STOCK_DIR"
        return 1
    fi
    cp -rf "$STOCK_DIR/brcm/"* "$FW_BRCM/" 2>/dev/null || true
    if [ -d "$STOCK_DIR/cypress" ]; then
        cp -rf "$STOCK_DIR/cypress/"* "$FW_CYPRESS/" 2>/dev/null || true
    fi
    rm -f "$STATE_FILE"
}

reload_brcmfmac() {
    rmmod brcmfmac_wcc 2>/dev/null || true
    modprobe -r brcmfmac 2>/dev/null || true
    sleep 0.5
    modprobe brcmfmac 2>/dev/null || true
    # Wait for wlan0 to appear
    local tries=0
    while [ $tries -lt 10 ] && ! ip link show wlan0 &>/dev/null; do
        sleep 0.5
        tries=$((tries + 1))
    done
}

case "${1:-status}" in
  on)
    if [ ! -d "$PATCHED_DIR/brcm" ]; then
        echo "ERROR: No patched firmware cached. Run the installer first."
        exit 1
    fi

    echo "Switching to monitor mode..."

    # Disconnect WiFi gracefully
    nmcli device disconnect wlan0 2>/dev/null || true
    sleep 0.3

    # Swap to patched firmware
    cp -rf "$PATCHED_DIR/brcm/"* "$FW_BRCM/" 2>/dev/null || true
    if [ -d "$PATCHED_DIR/cypress" ]; then
        cp -rf "$PATCHED_DIR/cypress/"* "$FW_CYPRESS/" 2>/dev/null || true
    fi

    # Reload driver with patched firmware
    reload_brcmfmac

    # Set monitor mode
    ip link set wlan0 down 2>/dev/null || true
    iw dev wlan0 set type monitor 2>/dev/null || true
    ip link set wlan0 up 2>/dev/null || true

    echo "monitor" > "$STATE_FILE"
    echo "Monitor mode ON — wlan0 is now in monitor mode"
    echo "RNDIS and Bluetooth are unaffected"
    ;;

  off)
    echo "Switching to managed mode..."

    # Restore stock firmware
    ip link set wlan0 down 2>/dev/null || true
    ensure_stock || exit 1

    # Reload driver with stock firmware
    reload_brcmfmac

    # Let NetworkManager manage WiFi
    nmcli device set wlan0 managed yes 2>/dev/null || true
    sleep 1
    nmcli device connect wlan0 2>/dev/null || true

    echo "Monitor mode OFF — WiFi reconnecting via NetworkManager"
    ;;

  restore)
    # Silent restore — called at boot by bjorn-wifi.service
    # Safety net: always ensure stock firmware is in /lib/firmware/
    # before brcmfmac is loaded, even if Pi was turned off during monitor mode.
    ensure_stock 2>/dev/null || true
    ;;

  load)
    # Load brcmfmac with stock firmware (called at boot by bjorn-wifi.service)
    ensure_stock 2>/dev/null || true
    modprobe brcmfmac 2>/dev/null || true
    # Wait for wlan0
    local tries=0
    while [ $tries -lt 15 ] && ! ip link show wlan0 &>/dev/null; do
        sleep 0.5
        tries=$((tries + 1))
    done
    if ip link show wlan0 &>/dev/null; then
        echo "brcmfmac loaded — wlan0 available"
    else
        echo "brcmfmac loaded — wlan0 not yet available (may need more time)"
    fi
    ;;

  status)
    if [ -f "$STATE_FILE" ]; then
        echo "monitor"
    else
        echo "managed"
    fi
    # Show interface state if available
    if command -v iw &>/dev/null && ip link show wlan0 &>/dev/null; then
        iw dev wlan0 info 2>/dev/null | grep -E "type|ssid" || true
    fi
    ;;

  *)
    echo "Usage: bjorn-monitor-mode {on|off|status|restore|load}"
    echo ""
    echo "  on       Switch to monitor mode (patched firmware)"
    echo "  off      Switch to managed mode (stock firmware, reconnect WiFi)"
    echo "  status   Show current WiFi mode"
    echo "  restore  Restore stock firmware silently (boot safety)"
    echo "  load     Load brcmfmac module (boot sequence)"
    exit 1
    ;;
esac
SCRIPTEOF
    chmod +x /usr/local/bin/bjorn-monitor-mode
    log "SUCCESS" "Installed /usr/local/bin/bjorn-monitor-mode"

    # ── Install bjorn-wifi.service ─────────────────────────────────
    log "INFO" "Installing bjorn-wifi.service (safe WiFi loading after USB gadget)..."
    cat > /etc/systemd/system/bjorn-wifi.service << 'SVCEOF'
[Unit]
Description=BJORN WiFi — restore stock firmware and load brcmfmac safely
# Wait for USB gadget (RNDIS) and Bluetooth to be ready first.
# This ensures RNDIS and BT PAN tethering always work, even if brcmfmac crashes.
After=usb-gadget.service bluetooth.service
Wants=usb-gadget.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Step 1: ALWAYS restore stock firmware (safety net — if Pi was off during monitor mode)
ExecStartPre=/usr/local/bin/bjorn-monitor-mode restore
# Step 2: Load brcmfmac with stock firmware — WiFi comes up in managed mode
ExecStart=/usr/local/bin/bjorn-monitor-mode load
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable bjorn-wifi.service >> "$LOG_FILE" 2>&1
    log "SUCCESS" "bjorn-wifi.service installed and enabled"
}
