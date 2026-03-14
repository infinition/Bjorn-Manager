#!/bin/bash
# BJORN Installer — Systemd services, scripts directory, helper scripts
# Sourced by install_bjorn.sh (requires 00-common.sh)

# Function to create the .scripts_bjorn directory
create_scripts_directory() {
    log "INFO" "Ensuring the .scripts_bjorn directory exists"
    if ensure_directory /home/$BJORN_USER/.scripts_bjorn ".scripts_bjorn directory"; then
        log "SUCCESS" ".scripts_bjorn directory is ready"
    else
        log "ERROR" "Failed to create .scripts_bjorn directory"
        failed_apt_packages+=(".scripts_bjorn directory creation")
        return 0
    fi
    if chown -R $BJORN_USER:$BJORN_USER /home/$BJORN_USER/.scripts_bjorn >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Set ownership for .scripts_bjorn directory"
    else
        log "ERROR" "Failed to set ownership for .scripts_bjorn directory"
        failed_apt_packages+=(".scripts_bjorn directory ownership")
    fi
}

# Generic function to setup Bjorn scripts
setup_bjorn_scripts() {
    log "INFO" "Starting installation of Bjorn scripts"
    DESTINATION_DIR="/home/$BJORN_USER/.scripts_bjorn"
    declare -A scripts=(
        ["bjorn_wifi.sh"]="/home/$BJORN_USER/Bjorn/bjorn_wifi.sh"
        ["bjorn_bluetooth.sh"]="/home/$BJORN_USER/Bjorn/bjorn_bluetooth.sh"
        ["bjorn_usb_gadget.sh"]="/home/$BJORN_USER/Bjorn/bjorn_usb_gadget.sh"
    )
    if [ ! -d "$DESTINATION_DIR" ]; then
        if ensure_directory "$DESTINATION_DIR" "scripts destination directory"; then
            log "SUCCESS" "Destination directory created: $DESTINATION_DIR"
        else
            log "ERROR" "Failed to create directory: $DESTINATION_DIR"
            echo -e "${RED}Failed to create the destination directory. Check the log for details.${NC}"
            failed_apt_packages+=("Create destination directory")
            return 0
        fi
    fi
    for script_name in "${!scripts[@]}"; do
        SOURCE_SCRIPT="${scripts[$script_name]}"
        DESTINATION_SCRIPT="$DESTINATION_DIR/$script_name"
        if [ ! -f "$SOURCE_SCRIPT" ]; then
            log "ERROR" "The script $script_name was not found at $SOURCE_SCRIPT"
            echo -e "${RED}The script $script_name is missing. Check the log for details.${NC}"
            failed_apt_packages+=("$script_name not found")
            continue
        fi

        if [ -f "$DESTINATION_SCRIPT" ] && cmp -s "$SOURCE_SCRIPT" "$DESTINATION_SCRIPT"; then
            log "INFO" "$script_name already exists and is up to date"
        else
            if [ -f "$DESTINATION_SCRIPT" ]; then
                log "INFO" "$script_name already exists; updating it"
            else
                log "INFO" "Installing $script_name"
            fi
            if cp "$SOURCE_SCRIPT" "$DESTINATION_SCRIPT" >> "$LOG_FILE" 2>&1; then
                log "SUCCESS" "Successfully copied $script_name to $DESTINATION_SCRIPT"
            else
                log "ERROR" "Failed to copy $script_name to $DESTINATION_SCRIPT"
                echo -e "${RED}Failed to copy $script_name. Check the log for details.${NC}"
                failed_apt_packages+=("Copy $script_name")
                continue
            fi
        fi
        if chmod +x "$DESTINATION_SCRIPT" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Executable permissions set for $script_name"
        else
            log "ERROR" "Failed to set executable permissions for $script_name"
            echo -e "${RED}Failed to set executable permissions for $script_name. Check the log for details.${NC}"
            failed_apt_packages+=("Set permissions for $script_name")
            continue
        fi
        log "SUCCESS" "$script_name installed successfully"
    done

    if [ -f "$DESTINATION_DIR/mode-switcher.sh" ]; then
        log "INFO" "Removing deprecated mode-switcher.sh from $DESTINATION_DIR"
        if rm -f "$DESTINATION_DIR/mode-switcher.sh" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Removed deprecated mode-switcher.sh"
        else
            log "WARNING" "Failed to remove deprecated mode-switcher.sh"
        fi
    else
        log "INFO" "Deprecated mode-switcher.sh is already absent"
    fi

    log "INFO" "Bjorn scripts installation completed"
}

# Configure systemd services (resilient creation)
setup_services() {
    log "INFO" "Setting up system services..."

    log_file_write_action /etc/systemd/system/bjorn.service "bjorn.service"
    cat > /etc/systemd/system/bjorn.service << EOF
[Unit]
Description=Bjorn Service
DefaultDependencies=no
Before=basic.target
After=local-fs.target

[Service]
ExecStart=/usr/bin/python3 /home/bjorn/Bjorn/Bjorn.py
WorkingDirectory=/home/bjorn/Bjorn
StandardOutput=inherit
StandardError=inherit
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Created bjorn.service file"
    else
        log "ERROR" "Failed to create bjorn.service file"
        failed_apt_packages+=("bjorn.service creation")
    fi

    # PAM limits
    ensure_line_in_file /etc/pam.d/common-session "session required pam_limits.so" "pam_limits session line" || failed_apt_packages+=("pam_limits in common-session")
    ensure_line_in_file /etc/pam.d/common-session-noninteractive "session required pam_limits.so" "pam_limits noninteractive session line" || failed_apt_packages+=("pam_limits in common-session-noninteractive")

    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { log "ERROR" "Failed to reload systemd daemon"; failed_apt_packages+=("systemd daemon reload"); }
    ensure_service_enabled bjorn.service "bjorn.service" || failed_apt_packages+=("bjorn.service enable")
    start_or_restart_service bjorn.service "bjorn.service" || failed_apt_packages+=("bjorn.service start")

    log "SUCCESS" "Services setup completed"
}
