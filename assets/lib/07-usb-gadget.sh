#!/bin/bash
# BJORN Installer — USB Gadget configuration (RNDIS networking + HID keyboard/mouse)
# Sourced by install_bjorn.sh (requires 00-common.sh, 01-platform.sh, 02-packages.sh)
#
# STRATEGY:
#   All USB functions (RNDIS networking + HID keyboard + HID mouse) are created
#   as a SINGLE composite gadget at boot time. You cannot hot-add HID functions
#   to a running gadget (UDC rebind fails with EIO when RNDIS is active).
#   The Loki engine simply opens /dev/hidg0 and /dev/hidg1 at runtime.

execute_usb_gadget_script() {
    log "INFO" "Setting up USB Gadget configuration (RNDIS + HID)..."

    # Detect boot files location
    BOOT_PAIR=$(detect_boot_paths)
    CMDLINE_FILE="${BOOT_PAIR%%|*}"
    CONFIG_TXT="${BOOT_PAIR##*|}"
    INTERFACES_FILE="/etc/network/interfaces"
    DNSMASQ_CONFIG="/etc/dnsmasq.d/usb0"

    # ── 1. dnsmasq (DHCP server) ──────────────────────────────
    if dpkg -l | grep -q "^ii.*dnsmasq "; then
        log "INFO" "dnsmasq is already installed"
    else
        log "INFO" "Installing DHCP server (dnsmasq)..."
        apt_install_safe "dnsmasq" || true
    fi

    log "INFO" "Configuring dnsmasq for usb0..."
    log_file_write_action "$DNSMASQ_CONFIG" "dnsmasq usb0 configuration"
    cat > "$DNSMASQ_CONFIG" << EOF
interface=usb0
dhcp-range=172.20.2.2,172.20.2.10,255.255.255.0,12h
EOF
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Created dnsmasq configuration for usb0"
    else
        log "ERROR" "Failed to create dnsmasq configuration"
        display_prompt "Failed to create dnsmasq configuration.\nCheck the log for details."
        failed_apt_packages+=("Configure dnsmasq")
    fi

    # ── 2. Kernel module loading (dwc2 + libcomposite) ────────
    if [[ "$ARCH" = "arm64" && "$OS_VERSION_ID" = "12" ]]; then
        log "INFO" "64-bit Bookworm detected -> using /etc/modules-load.d/"
        MODULES_FILE="/etc/modules-load.d/usb-gadget.conf"
        log_file_write_action "$MODULES_FILE" "USB gadget modules-load configuration"
        echo -e "dwc2\nlibcomposite" > "$MODULES_FILE"
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Created $MODULES_FILE with dwc2 + libcomposite"
        else
            log "ERROR" "Failed to create $MODULES_FILE"
            failed_apt_packages+=("modules-load.d for USB Gadget")
        fi
    else
        # 32-bit path: load dwc2 via cmdline, libcomposite via /etc/modules
        # NOTE: We do NOT load g_ether here — it's a monolithic gadget driver
        # that would race with libcomposite for the UDC. We use libcomposite only.
        MODULES_LOAD_NEW="modules-load=dwc2"
        MODULES_LOAD_OLD="modules-load=dwc2,g_ether"
        if [ -f "$CMDLINE_FILE" ]; then
            # Clean up old g_ether reference if present
            if grep -q "$MODULES_LOAD_OLD" "$CMDLINE_FILE"; then
                log "INFO" "Replacing old $MODULES_LOAD_OLD with $MODULES_LOAD_NEW in $CMDLINE_FILE"
                sed -i "s/$MODULES_LOAD_OLD/$MODULES_LOAD_NEW/" "$CMDLINE_FILE" >> "$LOG_FILE" 2>&1 || {
                    log "ERROR" "Failed to replace modules-load in $CMDLINE_FILE"
                    failed_apt_packages+=("Modify cmdline.txt for USB Gadget")
                }
            elif grep -q "$MODULES_LOAD_NEW" "$CMDLINE_FILE"; then
                log "INFO" "$MODULES_LOAD_NEW already present in $CMDLINE_FILE"
            else
                log "INFO" "Adding $MODULES_LOAD_NEW to $CMDLINE_FILE"
                sed -i "s/rootwait/rootwait $MODULES_LOAD_NEW/" "$CMDLINE_FILE" >> "$LOG_FILE" 2>&1 || {
                    log "ERROR" "Failed to add $MODULES_LOAD_NEW to $CMDLINE_FILE"
                    display_prompt "Failed to modify $CMDLINE_FILE.\nCheck the log for details."
                    failed_apt_packages+=("Modify cmdline.txt for USB Gadget")
                }
            fi
        else
            log "WARNING" "cmdline.txt not found at $CMDLINE_FILE"
            failed_apt_packages+=("cmdline.txt missing")
        fi

        # Ensure libcomposite is loaded via /etc/modules on 32-bit
        ensure_line_in_file /etc/modules "libcomposite" "libcomposite module" || failed_apt_packages+=("libcomposite in /etc/modules")
        # Remove g_ether from /etc/modules if present (conflicts with libcomposite)
        if grep -q "^g_ether" /etc/modules 2>/dev/null; then
            sed -i '/^g_ether/d' /etc/modules
            log "SUCCESS" "Removed g_ether from /etc/modules (replaced by libcomposite)"
        fi
    fi

    # ── 3. Modify config.txt (dtoverlay=dwc2) ─────────────────
    DTO_OVERLAY="dtoverlay=dwc2"
    if [ -f "$CONFIG_TXT" ]; then
        if grep -q "dtoverlay=dwc2\|otg_mode=1" "$CONFIG_TXT"; then
            log "INFO" "Existing USB configurations found, cleaning up..."
            temp_file=$(mktemp)
            sed -e '/dtoverlay=dwc2.*/d' -e '/otg_mode=1/d' "$CONFIG_TXT" > "$temp_file"
            cp "$temp_file" "$CONFIG_TXT"
            rm "$temp_file"
            log "SUCCESS" "Cleaned up existing USB configurations"
        fi
        if ! grep -q "^$DTO_OVERLAY$" "$CONFIG_TXT"; then
            log "INFO" "Adding $DTO_OVERLAY to main section of $CONFIG_TXT"
            temp_file=$(mktemp)
            awk '
            BEGIN {added=0}
            /^\[.*\]/ {
                if (!added) {
                    print ""
                    print "# USB gadget configuration"
                    print "dtoverlay=dwc2"
                    print ""
                    added=1
                }
            }
            { print }
            END {
                if (!added) {
                    print ""
                    print "# USB gadget configuration"
                    print "dtoverlay=dwc2"
                }
            }' "$CONFIG_TXT" > "$temp_file"
            cp "$temp_file" "$CONFIG_TXT"
            rm "$temp_file"
            [ $? -eq 0 ] && log "SUCCESS" "Added $DTO_OVERLAY to $CONFIG_TXT" || {
                log "ERROR" "Failed to add $DTO_OVERLAY to $CONFIG_TXT"
                display_prompt "Failed to modify $CONFIG_TXT.\nCheck the log for details."
                failed_apt_packages+=("Modify config.txt for USB Gadget")
            }
        else
            log "INFO" "$DTO_OVERLAY already present in main section of $CONFIG_TXT"
        fi
    else
        log "WARNING" "config.txt not found at $CONFIG_TXT"
        failed_apt_packages+=("config.txt missing")
    fi

    # ── 4. Create the composite USB Gadget script ─────────────
    #   RNDIS networking (usb0) + HID keyboard (hidg0) + HID mouse (hidg1)
    #   All created in ONE gadget BEFORE UDC bind — this is critical.
    USB_GADGET_SCRIPT="/usr/local/bin/usb-gadget.sh"
    log_file_write_action "$USB_GADGET_SCRIPT" "USB gadget runtime script"
    cat > "$USB_GADGET_SCRIPT" << 'GADGET_EOF'
#!/bin/bash
# usb-gadget.sh — USB composite gadget: RNDIS networking + HID (keyboard/mouse)
# Auto-generated by Bjorn installer. Do not edit manually.
#
# ARCHITECTURE:
#   One gadget (g1) with three functions all in configs/c.1:
#     - rndis.usb0  → creates usb0 network interface (DHCP via dnsmasq)
#     - hid.usb0    → creates /dev/hidg0 (keyboard, 8-byte boot protocol)
#     - hid.usb1    → creates /dev/hidg1 (mouse, 6-byte relative+absolute)
#
#   HID report descriptors are P4wnP1_aloa-compatible (exact byte copies).

set -e

GADGET_DIR="/sys/kernel/config/usb_gadget"
G="${GADGET_DIR}/g1"

cleanup() {
    cd "${GADGET_DIR}" 2>/dev/null || return
    if [ -d "g1" ]; then
        cd g1
        [ -f "UDC" ] && echo "" > UDC 2>/dev/null || true
        # Remove all symlinks from config
        for link in configs/c.1/*; do
            [ -L "$link" ] && rm "$link" 2>/dev/null || true
        done
        [ -L "os_desc/c.1" ] && rm "os_desc/c.1" 2>/dev/null || true
        [ -d "os_desc" ] && rmdir os_desc 2>/dev/null || true
        [ -d "configs/c.1/strings/0x409" ] && rmdir configs/c.1/strings/0x409 2>/dev/null || true
        [ -d "configs/c.1" ] && rmdir configs/c.1 2>/dev/null || true
        # Remove functions
        for func in functions/*; do
            [ -d "$func" ] && rmdir "$func" 2>/dev/null || true
        done
        [ -d "strings/0x409" ] && rmdir strings/0x409 2>/dev/null || true
        cd ..
        rmdir g1 2>/dev/null || true
    fi
}

wait_for_usb0() {
    local max_attempts=10
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if ip link show usb0 > /dev/null 2>&1; then
            echo "USB0 interface detected"
            return 0
        fi
        echo "Waiting for USB0 interface (attempt $attempt/$max_attempts)..."
        sleep 2
        attempt=$((attempt + 1))
    done
    return 1
}

if [ "$1" = "stop" ]; then
    cleanup
    exit 0
fi

echo "=== Starting USB composite gadget (RNDIS + HID) ==="

# Load required kernel modules
modprobe libcomposite 2>/dev/null || true
modprobe u_ether 2>/dev/null || true

# Clean up any previous gadget
cleanup

# ── Create gadget skeleton ────────────────────────────────────
cd "${GADGET_DIR}" || exit 1
mkdir -p g1
cd g1

echo 0x1d6b > idVendor     # Linux Foundation
echo 0x0104 > idProduct     # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB
echo 0xEF > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol

mkdir -p strings/0x409
echo "fedcba9876543210" > strings/0x409/serialnumber
echo "Raspberry Pi"      > strings/0x409/manufacturer
echo "Pi Zero USB"       > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "Config 1: RNDIS + HID" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

# ── Function 1: RNDIS networking ──────────────────────────────
mkdir -p functions/rndis.usb0
echo "02:12:34:56:78:9A" > functions/rndis.usb0/dev_addr
echo "02:98:76:54:32:10" > functions/rndis.usb0/host_addr
mkdir -p functions/rndis.usb0/os_desc/interface.rndis
echo "RNDIS" > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
echo "5162001" > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
echo "Created RNDIS function"

# Windows needs Microsoft OS descriptors for configfs RNDIS composite gadgets.
mkdir -p os_desc
echo 1 > os_desc/use
echo 0xcd > os_desc/b_vendor_code
echo "MSFT100" > os_desc/qw_sign

# ── Function 2 & 3: HID keyboard + mouse ─────────────────────
# Uses python3 to write binary report descriptors (bash can't handle null bytes)
python3 - <<'PYEOF'
import os, sys

G = "/sys/kernel/config/usb_gadget/g1"

# P4wnP1_aloa exact boot keyboard descriptor (63 bytes)
# Source: P4wnP1_aloa-master/service/SubSysUSB.go lines 54-70
KBD_DESC = bytes([
    0x05,0x01,0x09,0x06,0xa1,0x01,0x05,0x07,
    0x19,0xe0,0x29,0xe7,0x15,0x00,0x25,0x01,
    0x75,0x01,0x95,0x08,0x81,0x02,0x95,0x01,
    0x75,0x08,0x81,0x03,0x95,0x05,0x75,0x01,
    0x05,0x08,0x19,0x01,0x29,0x05,0x91,0x02,
    0x95,0x01,0x75,0x03,0x91,0x03,0x95,0x06,
    0x75,0x08,0x15,0x00,0x25,0x65,0x05,0x07,
    0x19,0x00,0x29,0x65,0x81,0x00,0xc0,
])

# P4wnP1_aloa dual-mode mouse descriptor (111 bytes)
# Report ID 1 = relative, Report ID 2 = absolute
MOUSE_DESC = bytes([
    0x05,0x01,0x09,0x02,0xa1,0x01,0x09,0x01,
    0xa1,0x00,0x85,0x01,0x05,0x09,0x19,0x01,
    0x29,0x03,0x15,0x00,0x25,0x01,0x95,0x03,
    0x75,0x01,0x81,0x02,0x95,0x01,0x75,0x05,
    0x81,0x03,0x05,0x01,0x09,0x30,0x09,0x31,
    0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x02,
    0x81,0x06,0x95,0x02,0x75,0x08,0x81,0x01,
    0xc0,0xc0,0x05,0x01,0x09,0x02,0xa1,0x01,
    0x09,0x01,0xa1,0x00,0x85,0x02,0x05,0x09,
    0x19,0x01,0x29,0x03,0x15,0x00,0x25,0x01,
    0x95,0x03,0x75,0x01,0x81,0x02,0x95,0x01,
    0x75,0x05,0x81,0x01,0x05,0x01,0x09,0x30,
    0x09,0x31,0x15,0x00,0x26,0xff,0x7f,0x95,
    0x02,0x75,0x10,0x81,0x02,0xc0,0xc0,
])

def w(path, content):
    with open(path, "w") as f:
        f.write(content)

def wb(path, data):
    with open(path, "wb") as f:
        f.write(data)

try:
    # Keyboard → /dev/hidg0
    kbd = G + "/functions/hid.usb0"
    os.makedirs(kbd, exist_ok=True)
    w(kbd + "/protocol", "1")       # Boot protocol (keyboard)
    w(kbd + "/subclass", "1")       # Boot interface subclass
    w(kbd + "/report_length", "8")  # 8-byte keyboard reports
    wb(kbd + "/report_desc", KBD_DESC)
    print(f"HID keyboard created: {len(KBD_DESC)} bytes descriptor → /dev/hidg0")

    # Mouse → /dev/hidg1
    mouse = G + "/functions/hid.usb1"
    os.makedirs(mouse, exist_ok=True)
    w(mouse + "/protocol", "2")       # Mouse protocol
    w(mouse + "/subclass", "1")       # Boot interface subclass
    w(mouse + "/report_length", "6")  # 6-byte mouse reports
    wb(mouse + "/report_desc", MOUSE_DESC)
    print(f"HID mouse created: {len(MOUSE_DESC)} bytes descriptor → /dev/hidg1")

except Exception as e:
    print(f"WARNING: HID setup failed (non-fatal, RNDIS still works): {e}", file=sys.stderr)
    sys.exit(0)  # Exit 0 so we don't block RNDIS setup
PYEOF

# ── Symlink ALL functions into config ─────────────────────────
# Order matters: RNDIS first, then HID (some hosts enumerate in order)
for func in rndis.usb0 hid.usb0 hid.usb1; do
    [ -L "configs/c.1/$func" ] && rm "configs/c.1/$func"
    if [ -d "functions/$func" ]; then
        ln -s "functions/$func" "configs/c.1/" 2>/dev/null && \
            echo "Linked $func into config" || \
            echo "WARNING: Failed to link $func (non-fatal)"
    fi
done

[ -L "os_desc/c.1" ] || ln -s "configs/c.1" "os_desc/" 2>/dev/null || true

# ── Bind UDC ──────────────────────────────────────────────────
sleep 3
UDC_NAME="$(ls /sys/class/udc 2>/dev/null | head -n1)"
if [ -n "$UDC_NAME" ]; then
    echo "$UDC_NAME" > UDC
    echo "Assigned UDC: $UDC_NAME"
    sleep 3
else
    echo "Error: No UDC found under /sys/class/udc"
    ls -l /sys/class/udc/ 2>/dev/null
    exit 1
fi

# ── Wait for network interface ────────────────────────────────
if ! wait_for_usb0; then
    echo "Warning: USB0 interface did not appear (HID may still work)"
fi

# ── Configure network ────────────────────────────────────────
ip link set usb0 up 2>/dev/null || true
ip addr add 172.20.2.1/24 dev usb0 2>/dev/null || true
echo "Network interface configured"

# ── Start DHCP ────────────────────────────────────────────────
if systemctl --no-block restart dnsmasq 2>/dev/null; then
    echo "DHCP server started"
else
    echo "Warning: Failed to restart DHCP server"
fi

# ── Report HID device status ─────────────────────────────────
echo "=== Gadget status ==="
[ -c /dev/hidg0 ] && echo "  /dev/hidg0 (keyboard): READY" || echo "  /dev/hidg0 (keyboard): NOT FOUND"
[ -c /dev/hidg1 ] && echo "  /dev/hidg1 (mouse):    READY" || echo "  /dev/hidg1 (mouse):    NOT FOUND"
ip addr show usb0 2>/dev/null | grep inet && echo "  usb0 (network):        READY" || echo "  usb0 (network):        NOT FOUND"
echo "=== Composite gadget setup complete ==="
GADGET_EOF
    chmod +x "$USB_GADGET_SCRIPT"
    log "SUCCESS" "Created composite USB Gadget script (RNDIS + HID)"

    # ── 5. Create the systemd service ─────────────────────────
    USB_GADGET_SERVICE="/etc/systemd/system/usb-gadget.service"
    log_file_write_action "$USB_GADGET_SERVICE" "usb-gadget.service"
    cat > "$USB_GADGET_SERVICE" << EOF
[Unit]
Description=USB Composite Gadget Service (RNDIS + HID)
After=network.target
Before=dnsmasq.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 2
ExecStart=/usr/local/bin/usb-gadget.sh
ExecStop=/usr/local/bin/usb-gadget.sh stop
TimeoutStartSec=60
TimeoutStopSec=10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # ── 6. Configure usb0 interface (legacy 32-bit only) ──────
    if [[ "$ARCH" != "arm64" ]]; then
        if [ ! -f "/etc/network/interfaces" ]; then
            log "INFO" "Creating /etc/network/interfaces file..."
            touch /etc/network/interfaces && chmod 644 /etc/network/interfaces
            log "SUCCESS" "Created /etc/network/interfaces file"
        fi

        INTERFACE_CONFIG="allow-hotplug usb0
iface usb0 inet static
    address 172.20.2.1
    netmask 255.255.255.0"
        if grep -q "allow-hotplug usb0" "$INTERFACES_FILE"; then
            log "INFO" "usb0 interface already configured in $INTERFACES_FILE"
        else
            log "INFO" "Adding usb0 interface configuration to $INTERFACES_FILE"
            echo -e "\n$INTERFACE_CONFIG" >> "$INTERFACES_FILE"
        fi
    else
        log "INFO" "Skipping /etc/network/interfaces configuration (systemd-networkd preferred on 64-bit)"
    fi

    # ── 7. Enable/start services ──────────────────────────────
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { log "ERROR" "Failed to reload systemd daemon (usb gadget)"; failed_apt_packages+=("systemd daemon reload (usb gadget)"); }
    ensure_service_enabled dnsmasq.service "dnsmasq.service" || failed_apt_packages+=("dnsmasq.service enable")
    start_or_restart_service dnsmasq.service "dnsmasq.service" || failed_apt_packages+=("dnsmasq.service start")
    ensure_service_enabled usb-gadget.service "usb-gadget.service" || failed_apt_packages+=("usb-gadget.service enable")
    if systemctl is-active --quiet usb-gadget.service 2>/dev/null; then
        if systemctl restart usb-gadget.service >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Restarted usb-gadget.service"
        else
            log "WARNING" "usb-gadget.service could not be restarted immediately. A reboot will apply the USB gadget stack cleanly."
        fi
    else
        if systemctl start usb-gadget.service >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Started usb-gadget.service"
        else
            log "WARNING" "usb-gadget.service did not start immediately. This is usually expected until after reboot when dwc2/libcomposite boot changes take effect."
        fi
    fi

    # ── 8. Verify HID devices (informational) ─────────────────
    if [ -c /dev/hidg0 ]; then
        log "SUCCESS" "/dev/hidg0 (keyboard) is available"
    else
        log "INFO" "/dev/hidg0 not yet available (will appear after reboot)"
    fi
    if [ -c /dev/hidg1 ]; then
        log "SUCCESS" "/dev/hidg1 (mouse) is available"
    else
        log "INFO" "/dev/hidg1 not yet available (will appear after reboot)"
    fi

    display_prompt "USB Composite Gadget configured: RNDIS + HID (keyboard/mouse).\nDHCP auto-assigns IPs on usb0.\nHID devices: /dev/hidg0 (keyboard) + /dev/hidg1 (mouse).\nA reboot is required for HID to become active."
}
