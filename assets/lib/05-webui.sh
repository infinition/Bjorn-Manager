#!/bin/bash
# BJORN Installer — Web UI authentication setup
# Sourced by install_bjorn.sh (requires 00-common.sh)

setup_webui_auth() {
    log "INFO" "Setting up Web UI authentication..."
    SETTINGS_DIR="/home/$BJORN_USER/.settings_bjorn"
    WEBAPP_JSON="$SETTINGS_DIR/webapp.json"

    if [[ "$enable_auth" =~ ^[Yy]$ ]]; then
        log "INFO" "User enabled Web UI authentication."
        if ensure_directory "$SETTINGS_DIR" ".settings_bjorn directory"; then
            log "SUCCESS" ".settings_bjorn directory is ready"
        else
            log "ERROR" "Failed to create .settings_bjorn directory"
            echo -e "${RED}Failed to create .settings_bjorn directory. Check the log for details.${NC}"
            failed_pip_packages+=(".settings_bjorn directory creation")
            return 0
        fi

        log_file_write_action "$WEBAPP_JSON" "webapp.json"
        cat > "$WEBAPP_JSON" << EOF
{
    "username": "bjorn",
    "password": "$WEBUI_PASSWORD",
    "always_require_auth": true
}
EOF
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Created webapp.json with user-provided password."
        else
            log "ERROR" "Failed to create webapp.json with user-provided password."
            echo -e "${RED}Failed to create webapp.json. Check the log for details.${NC}"
            failed_pip_packages+=("webapp.json creation for Web UI authentication")
        fi

    else
        log "INFO" "User chose not to enable Web UI authentication."

        if [ -f "/home/$BJORN_USER/Bjorn/shared.py" ]; then
            if grep -qi '"webauth":[[:space:]]*false' /home/$BJORN_USER/Bjorn/shared.py; then
                log "INFO" "'webauth' is already disabled in shared.py"
            else
                sed -i 's/"webauth":[[:space:]]*true/"webauth": false/I; s/"webauth":[[:space:]]*"true"/"webauth": false/I' /home/$BJORN_USER/Bjorn/shared.py >> "$LOG_FILE" 2>&1
                if [ $? -eq 0 ]; then
                    log "SUCCESS" "Set 'webauth' to false in shared.py"
                else
                    log "ERROR" "Failed to set 'webauth' to false in shared.py"
                    echo -e "${RED}Failed to modify shared.py. Check the log for details.${NC}"
                    failed_pip_packages+=("'webauth' in shared.py")
                fi
            fi

            if ensure_directory "$SETTINGS_DIR" ".settings_bjorn directory"; then
                log "SUCCESS" ".settings_bjorn directory is ready"
            else
                log "ERROR" "Failed to create .settings_bjorn directory"
                echo -e "${RED}Failed to create .settings_bjorn directory. Check the log for details.${NC}"
                failed_pip_packages+=(".settings_bjorn directory creation")
            fi

            log_file_write_action "$WEBAPP_JSON" "webapp.json"
            cat > "$WEBAPP_JSON" << EOF
{
    "username": "bjorn",
    "password": "bjorn",
    "always_require_auth": false
}
EOF
            if [ $? -eq 0 ]; then
                log "SUCCESS" "Created webapp.json with default credentials."
            else
                log "ERROR" "Failed to create webapp.json with default credentials."
                echo -e "${RED}Failed to create webapp.json. Check the log for details.${NC}"
                failed_pip_packages+=("webapp.json creation with default credentials")
            fi
        else
            log "ERROR" "shared.py not found to modify 'webauth' setting."
            echo -e "${RED}shared.py not found. Check the log for details.${NC}"
            failed_pip_packages+=("shared.py not found")
        fi
    fi
}
