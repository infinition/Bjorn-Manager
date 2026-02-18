#!/bin/bash
# BJORN Installer — Core BJORN setup (clone, pip deps, config)
# Sourced by install_bjorn.sh (requires 00-common.sh, 01-platform.sh, 02-packages.sh)

# Git branch to clone (default: main, overridable via env or CLI)
: "${GIT_BRANCH:=main}"

setup_bjorn() {
    log "INFO" "Setting up BJORN..."

    # Ensure bjorn user exists
    if ! id -u $BJORN_USER >/dev/null 2>&1; then
        if adduser --disabled-password --gecos "" $BJORN_USER >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Created BJORN user"
        else
            log "ERROR" "Failed to create BJORN user"
            echo -e "${RED}Failed to create BJORN user. Check the log for details.${NC}"
            failed_apt_packages+=("BJORN user creation")
            return 0
        fi
    fi

    # Move to /home/bjorn
    cd /home/$BJORN_USER || {
        log "ERROR" "Cannot access /home/$BJORN_USER"
        echo -e "${RED}Cannot access /home/$BJORN_USER. Check the log for details.${NC}"
        failed_apt_packages+=("Accessing /home/$BJORN_USER")
        return 0
    }

    # Clone repo if needed (skipped in debug, but require existing dir)
    if [ -d "Bjorn" ]; then
        log "INFO" "Using existing BJORN directory"
        echo -e "${GREEN}Using existing BJORN directory${NC}"
    else
        if [ "$DEBUG_MODE" = false ]; then
            log "INFO" "Cloning BJORN repository (branch: $GIT_BRANCH)"
            if git clone -b "$GIT_BRANCH" https://github.com/infinition/Bjorn.git >> "$LOG_FILE" 2>&1; then
                log "SUCCESS" "Cloned BJORN repository (branch: $GIT_BRANCH)"
            else
                log "ERROR" "Failed to clone BJORN repository"
                echo -e "${RED}Failed to clone BJORN repository. Check the log for details.${NC}"
                failed_apt_packages+=("Cloning BJORN repository")
                return 0
            fi
        else
            log "WARNING" "Debug mode enabled: Skipping git clone. Ensure the Bjorn directory exists."
            echo -e "${YELLOW}Debug mode enabled: Skipping git clone. Ensure the Bjorn directory exists.${NC}"
            if [ ! -d "Bjorn" ]; then
                log "ERROR" "Bjorn directory does not exist in /home/$BJORN_USER/."
                echo -e "${RED}Bjorn directory missing in debug mode.${NC}"
                failed_apt_packages+=("Bjorn directory in debug mode")
                return 0
            fi
        fi
    fi

    # Enter project dir
    cd Bjorn || {
        log "ERROR" "Cannot access Bjorn directory"
        echo -e "${RED}Cannot access Bjorn directory. Check the log for details.${NC}"
        failed_apt_packages+=("Accessing Bjorn directory")
        return 0
    }

    # Patch shared.py with selected EPD & mode
    if [ -f "shared.py" ]; then
        sed -i '/"epd_type": "epd2in13_V4",/s/"epd2in13_V4"/"'"$EPD_VERSION"'"/' shared.py >> "$LOG_FILE" 2>&1
        [ $? -eq 0 ] && log "SUCCESS" "Updated 'epd_type' in shared.py" \
                     || { log "ERROR" "Failed to update 'epd_type'"; failed_pip_packages+=("'epd_type' in shared.py"); }

        sed -i '/"manual_mode":/s/True\|False/'"$MANUAL_MODE"'/' shared.py >> "$LOG_FILE" 2>&1
        [ $? -eq 0 ] && log "SUCCESS" "Updated 'manual_mode' in shared.py" \
                     || { log "ERROR" "Failed to update 'manual_mode'"; failed_pip_packages+=("'manual_mode' in shared.py"); }

        # Backups & settings dirs
        log "INFO" "Creating backup directories and archive..."
        if mkdir -p /home/$BJORN_USER/.backups_bjorn /home/$BJORN_USER/.settings_bjorn >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Created backup and settings directories"
        else
            log "ERROR" "Failed to create backup/settings directories"
            failed_pip_packages+=("Backup and settings directories creation")
        fi

        # Move character configurations
        log "INFO" "Moving character configurations to .settings_bjorn directory"
        if mv /home/$BJORN_USER/Bjorn/resources/default_config/characters/* /home/$BJORN_USER/.settings_bjorn/ >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Moved character configurations"
        else
            log "ERROR" "Failed to move character configurations"
            failed_pip_packages+=("Moving character configurations")
        fi

        # Ownership
        if chown -R $BJORN_USER:$BJORN_USER /home/$BJORN_USER/.settings_bjorn/ >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Set ownership for .settings_bjorn"
        else
            log "ERROR" "Failed to set ownership for .settings_bjorn"
            failed_pip_packages+=(".settings_bjorn directory ownership")
        fi

        # Create timestamped backup
        timestamp=$(date '+%Y%m%d%H%M%S')
        archive_name="SCRIPT_${timestamp}.tar.gz"
        archive_path="/home/$BJORN_USER/.backups_bjorn/${archive_name}"
        if tar -czf "$archive_path" -C /home/$BJORN_USER Bjorn >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Created backup archive: $archive_name"
        else
            log "ERROR" "Failed to create backup archive: $archive_name"
            failed_pip_packages+=("Backup archive creation")
        fi

        # JSON metadata
        json_file="${archive_name}.json"
        json_path="/home/$BJORN_USER/.backups_bjorn/${json_file}"
        current_date=$(date '+%Y-%m-%d %H:%M:%S')
        backup_filename="${archive_name}"
        cat > "$json_path" << EOF
{
    "filename": "${backup_filename}",
    "description": "Default Bjorn Backup from installation script",
    "date": "${current_date}",
    "is_default": true
}
EOF
        [ $? -eq 0 ] && log "SUCCESS" "Created backup metadata JSON: $json_file" \
                     || { log "ERROR" "Failed to create backup metadata JSON: $json_file"; failed_pip_packages+=("Backup metadata JSON creation"); }

    else
        log "ERROR" "Configuration file not found: shared.py"
        echo -e "${RED}Configuration file shared.py not found. Check the log for details.${NC}"
        failed_pip_packages+=("shared.py not found")
        return 0
    fi

    # Python requirements (line-by-line) with break-system-packages preference
    log "INFO" "Installing Python requirements..."
    if [ -f "requirements.txt" ]; then
        # Define skip list for heavy libs on armv6 (Zero 1) handled via APT
        if [ "$IS_ARMV6" -eq 1 ]; then
            ZERO1_SKIP_RE='^(paramiko|cryptography|bcrypt|pynacl|numpy)([[:space:]=<>].*)?$'
        else
            ZERO1_SKIP_RE=''
        fi

        while IFS= read -r requirement || [ -n "$requirement" ]; do
            # normalize: trim
            requirement="$(echo "$requirement" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            # skip blanks and comments
            if [ -z "$requirement" ] || [[ "$requirement" =~ ^# ]]; then
                continue
            fi

            # On Zero 1, skip heavy ones (already installed via APT)
            if [ "$IS_ARMV6" -eq 1 ] && echo "$requirement" | tr '[:upper:]' '[:lower:]' | grep -Eq "$ZERO1_SKIP_RE"; then
                log "INFO" "armv6: skipping pip install of '$requirement' (handled by APT)"
                continue
            fi

            log "INFO" "Installing Python package: $requirement"
            PIP_ARGS="--prefer-binary --no-build-isolation"

            if [ "$INSTALL_MODE" = "local" ] && [ -d "${PACKAGES_PATH}/pip" ]; then
                if pip_install $PIP_ARGS --no-index --find-links="${PACKAGES_PATH}/pip" "$requirement"; then
                    log "SUCCESS" "Installed Python package: $requirement"
                else
                    log "ERROR" "Failed to install Python package: $requirement (local)"
                    failed_pip_packages+=("$requirement")
                fi
            else
                if pip_install $PIP_ARGS "$requirement"; then
                    log "SUCCESS" "Installed Python package: $requirement"
                else
                    log "ERROR" "Failed to install Python package: $requirement"
                    failed_pip_packages+=("$requirement")
                fi
            fi
        done < requirements.txt
    else
        log "ERROR" "requirements.txt not found."
        echo -e "${RED}requirements.txt not found. Skipping Python package installations.${NC}"
        failed_pip_packages+=("requirements.txt not found")
    fi

    # Additional critical pip packages (not always in requirements.txt)
    log "INFO" "Installing additional pip packages..."
    for extra_pkg in "RPi.GPIO" "netifaces" "paramiko" "scapy" "telnetlib3"; do
        log "INFO" "Installing pip package: $extra_pkg"
        if pip_install --prefer-binary "$extra_pkg"; then
            log "SUCCESS" "Installed pip package: $extra_pkg"
        else
            log "WARNING" "Failed to install pip package: $extra_pkg (non-fatal)"
            failed_pip_packages+=("$extra_pkg")
        fi
    done

    # Permissions on project
    if chown -R $BJORN_USER:$BJORN_USER /home/$BJORN_USER/Bjorn >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Set ownership for Bjorn directory"
    else
        log "ERROR" "Failed to set ownership for Bjorn directory"
        failed_apt_packages+=("Bjorn directory ownership")
    fi

    if chmod -R 755 /home/$BJORN_USER/Bjorn >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Set permissions for Bjorn directory"
    else
        log "ERROR" "Failed to set permissions for Bjorn directory"
        failed_apt_packages+=("Bjorn directory permissions")
    fi

    # Groups for hardware access
    if usermod -a -G spi,gpio,i2c $BJORN_USER >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Added bjorn user to required groups"
    else
        log "ERROR" "Failed to add bjorn user to required groups"
        failed_apt_packages+=("Adding bjorn user to groups")
    fi
}
