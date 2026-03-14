#!/bin/bash
# BJORN Installer — System configuration (limits, interfaces, wifi)
# Sourced by install_bjorn.sh (requires 00-common.sh)

# Function to configure system limits
configure_system_limits() {
    log "INFO" "Configuring system limits..."

    ensure_line_in_file /etc/security/limits.conf "* soft nofile 65535" "soft nofile limit" || failed_apt_packages+=("limits.conf soft nofile")
    ensure_line_in_file /etc/security/limits.conf "* hard nofile 65535" "hard nofile limit" || failed_apt_packages+=("limits.conf hard nofile")
    ensure_line_in_file /etc/security/limits.conf "root soft nofile 65535" "root soft nofile limit" || failed_apt_packages+=("limits.conf root soft nofile")
    ensure_line_in_file /etc/security/limits.conf "root hard nofile 65535" "root hard nofile limit" || failed_apt_packages+=("limits.conf root hard nofile")

    remove_lines_matching /etc/systemd/system.conf '^#?DefaultLimitNOFILE=' "DefaultLimitNOFILE entries" || failed_apt_packages+=("system.conf DefaultLimitNOFILE cleanup")
    ensure_line_in_file /etc/systemd/system.conf "DefaultLimitNOFILE=65535" "DefaultLimitNOFILE setting" || failed_apt_packages+=("system.conf DefaultLimitNOFILE")

    remove_lines_matching /etc/systemd/user.conf '^#?DefaultLimitNOFILE=' "DefaultLimitNOFILE entries" || failed_apt_packages+=("user.conf DefaultLimitNOFILE cleanup")
    ensure_line_in_file /etc/systemd/user.conf "DefaultLimitNOFILE=65535" "DefaultLimitNOFILE setting" || failed_apt_packages+=("user.conf DefaultLimitNOFILE")

    log_file_write_action /etc/security/limits.d/90-nofile.conf "nofile limits drop-in"
    cat > /etc/security/limits.d/90-nofile.conf << EOF
root soft nofile 65535
root hard nofile 65535
EOF
    ensure_line_in_file /etc/sysctl.conf "fs.file-max = 2097152" "fs.file-max setting" || failed_apt_packages+=("sysctl fs.file-max")
    if sysctl -p >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Configured sysctl settings"
    else
        log "ERROR" "Failed to configure sysctl settings"
        echo -e "${RED}Failed to configure sysctl settings. Check the log for details.${NC}"
        failed_apt_packages+=("sysctl configuration")
    fi
    log "SUCCESS" "System limits configuration completed"
}

# Configure SPI and I2C
configure_interfaces() {
    log "INFO" "Configuring SPI and I2C interfaces..."

    # Enable SPI and I2C using raspi-config
    raspi-config nonint do_spi 0
    raspi-config nonint do_i2c 0

    check_success "Interface configuration completed"
}

# Function to manage Wi-Fi connections
manage_wifi_connections() {
    log "INFO" "Managing Wi-Fi connections..."

    PRECONFIG_FILE="/etc/NetworkManager/system-connections/preconfigured.nmconnection"

    if [ -f "$PRECONFIG_FILE" ]; then
        log "INFO" "Extracting data from preconfigured Wi-Fi connection..."
        SSID=$(grep '^ssid=' "$PRECONFIG_FILE" | cut -d'=' -f2)
        PSK=$(grep '^psk=' "$PRECONFIG_FILE" | cut -d'=' -f2)

        if [ -z "$SSID" ]; then
            log "ERROR" "SSID not found in preconfigured file."
            echo -e "${RED}SSID not found in preconfigured Wi-Fi file. Check the log for details.${NC}"
            failed_apt_packages+=("SSID extraction from preconfigured Wi-Fi")
            return 0
        fi

        # Create a new connection named after the SSID with priority 5, IPv6 disabled
        log "INFO" "Preparing Wi-Fi connection for SSID: $SSID with priority 5 and IPv6 disabled"
        if command -v nmcli >/dev/null 2>&1; then
            if nmcli -t -f NAME connection show | grep -Fxq "$SSID"; then
                log "INFO" "Wi-Fi connection for SSID $SSID already exists; updating it"
                if nmcli connection modify "$SSID" \
                    connection.interface-name wlan0 \
                    802-11-wireless.ssid "$SSID" \
                    wifi-sec.key-mgmt wpa-psk \
                    wifi-sec.psk "$PSK" \
                    connection.autoconnect yes \
                    connection.autoconnect-priority 5 \
                    ipv4.method auto \
                    ipv6.method ignore >> "$LOG_FILE" 2>&1; then
                    log "SUCCESS" "Updated existing Wi-Fi connection for SSID: $SSID"
                else
                    log "ERROR" "Failed to update Wi-Fi connection for SSID: $SSID"
                    echo -e "${RED}Failed to update Wi-Fi connection for SSID: $SSID. Check the log for details.${NC}"
                    failed_apt_packages+=("Update Wi-Fi connection for SSID: $SSID")
                fi
            else
                if nmcli connection add type wifi ifname wlan0 con-name "$SSID" ssid "$SSID" \
                    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" \
                    connection.autoconnect yes connection.autoconnect-priority 5 \
                    ipv4.method auto ipv6.method ignore >> "$LOG_FILE" 2>&1; then
                    log "SUCCESS" "Created new Wi-Fi connection for SSID: $SSID (IPv6 disabled)"
                else
                    log "ERROR" "Failed to create Wi-Fi connection for SSID: $SSID"
                    echo -e "${RED}Failed to create Wi-Fi connection for SSID: $SSID. Check the log for details.${NC}"
                    failed_apt_packages+=("Wi-Fi connection for SSID: $SSID")
                fi
            fi
        else
            log "WARNING" "NetworkManager (nmcli) not available; skipping Wi-Fi nmcli configuration"
        fi

        rm -f "$PRECONFIG_FILE"
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Removed preconfigured Wi-Fi connection file."
        else
            log "WARNING" "Failed to remove preconfigured Wi-Fi connection file."
        fi
    else
        log "WARNING" "No preconfigured Wi-Fi connection file found."
    fi
}
