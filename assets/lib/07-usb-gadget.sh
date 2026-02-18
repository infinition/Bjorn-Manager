#!/bin/bash
# BJORN Installer — USB Gadget configuration (adaptive boot paths, resilient)
# Sourced by install_bjorn.sh (requires 00-common.sh, 01-platform.sh, 02-packages.sh)

execute_usb_gadget_script() {
    log "INFO" "Setting up USB Gadget configuration..."

    # Detect boot files location
    BOOT_PAIR=$(detect_boot_paths)
    CMDLINE_FILE="${BOOT_PAIR%%|*}"
    CONFIG_TXT="${BOOT_PAIR##*|}"
    INTERFACES_FILE="/etc/network/interfaces"
    DNSMASQ_CONFIG="/etc/dnsmasq.d/usb0"

    # dnsmasq presence
    if dpkg -l | grep -q "^ii.*dnsmasq "; then
        log "INFO" "dnsmasq is already installed"
    else
        log "INFO" "Installing DHCP server (dnsmasq)..."
        apt_install_safe "dnsmasq" || true
    fi

    # Configure dnsmasq for usb0
    log "INFO" "Configuring dnsmasq for usb0..."
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

    # === Adaptive handling of module loading (32-bit vs 64-bit) ===
    if [[ "$ARCH" = "arm64" && "$OS_VERSION_ID" = "12" ]]; then
        log "INFO" "64-bit Bookworm detected -> using /etc/modules-load.d/"
        MODULES_FILE="/etc/modules-load.d/usb-gadget.conf"
        echo -e "dwc2\ng_ether" > "$MODULES_FILE"
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Created $MODULES_FILE with dwc2 + g_ether"
        else
            log "ERROR" "Failed to create $MODULES_FILE"
            failed_apt_packages+=("modules-load.d for USB Gadget")
        fi
    else
        MODULES_LOAD="modules-load=dwc2,g_ether"
        if [ -f "$CMDLINE_FILE" ]; then
            if grep -q "$MODULES_LOAD" "$CMDLINE_FILE"; then
                log "INFO" "$MODULES_LOAD already present in $CMDLINE_FILE"
            else
                log "INFO" "Adding $MODULES_LOAD to $CMDLINE_FILE"
                sed -i "s/rootwait/rootwait $MODULES_LOAD/" "$CMDLINE_FILE" >> "$LOG_FILE" 2>&1 || {
                    log "ERROR" "Failed to add $MODULES_LOAD to $CMDLINE_FILE"
                    display_prompt "Failed to modify $CMDLINE_FILE.\nCheck the log for details."
                    failed_apt_packages+=("Modify cmdline.txt for USB Gadget")
                }
            fi
        else
            log "WARNING" "cmdline.txt not found at $CMDLINE_FILE"
            failed_apt_packages+=("cmdline.txt missing")
        fi
    fi

    # 2. Modify config.txt
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

    # 3. Create the USB Gadget script
    USB_GADGET_SCRIPT="/usr/local/bin/usb-gadget.sh"
    log "INFO" "Creating USB Gadget script at $USB_GADGET_SCRIPT"
    cat > "$USB_GADGET_SCRIPT" << 'EOF'
#!/bin/bash
cleanup() {
    cd /sys/kernel/config/usb_gadget/ 2>/dev/null || return
    if [ -d "g1" ]; then
        cd g1
        [ -f "UDC" ] && echo "" > UDC 2>/dev/null || true
        rm -f configs/c.1/ecm.usb0 2>/dev/null || true
        [ -d "configs/c.1/strings/0x409" ] && rmdir configs/c.1/strings/0x409 2>/dev/null || true
        [ -d "configs/c.1" ] && rmdir configs/c.1 2>/dev/null || true
        [ -d "functions/ecm.usb0" ] && rmdir functions/ecm.usb0 2>/dev/null || true
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
echo "Debug: Starting USB gadget configuration"
modprobe libcomposite 2>/dev/null || true
modprobe u_ether 2>/dev/null || true
cleanup
cd /sys/kernel/config/usb_gadget/ || exit 1
mkdir -p g1 || exit 1
cd g1
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB
mkdir -p strings/0x409
echo "fedcba9876543210" > strings/0x409/serialnumber
echo "Raspberry Pi" > strings/0x409/manufacturer
echo "Pi Zero USB Device" > strings/0x409/product
mkdir -p configs/c.1/strings/0x409
echo "Config 1: ECM network" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower
mkdir -p functions/ecm.usb0
ln -s functions/ecm.usb0 configs/c.1/
sleep 3
UDC_NAME="$(ls /sys/class/udc 2>/dev/null | head -n1)"
if [ -n "$UDC_NAME" ]; then
    echo "$UDC_NAME" > UDC
    sleep 3
else
    echo "Error: No UDC found under /sys/class/udc"
    ls -l /sys/class/udc/
    exit 1
fi
if ! wait_for_usb0; then
    echo "Error: USB0 interface did not appear after waiting"
    exit 1
fi
ip link set usb0 up
ip addr add 172.20.2.1/24 dev usb0 2>/dev/null || true
echo "Network interface configured"
if systemctl restart dnsmasq; then
    echo "DHCP server started"
    exit 0
else
    echo "Warning: Failed to restart DHCP server"
    exit 1
fi
EOF
    chmod +x "$USB_GADGET_SCRIPT"

    # 4. Create the systemd service
    USB_GADGET_SERVICE="/etc/systemd/system/usb-gadget.service"
    log "INFO" "Creating systemd service at $USB_GADGET_SERVICE"
    cat > "$USB_GADGET_SERVICE" << EOF
[Unit]
Description=USB Gadget Service
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

    # 5. Configure usb0 interface (legacy only, skipped on Bookworm)
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

    # Enable/start services
    systemctl enable dnsmasq
    systemctl start dnsmasq
    systemctl daemon-reload
    systemctl enable usb-gadget
    systemctl start usb-gadget

    display_prompt "USB Gadget configuration with DHCP completed.\nEnsure no duplicate entries exist in configuration files.\nDHCP will automatically assign IP addresses to connected devices."
}
