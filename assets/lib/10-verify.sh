#!/bin/bash
# BJORN Installer â€” Installation verification
# Sourced by install_bjorn.sh (requires 00-common.sh)

BJORN_VERIFY_NEEDS_LOGS=0

# Verify installation (non-fatal checks)
verify_installation() {
    log "INFO" "Verifying installation..."
    BJORN_VERIFY_NEEDS_LOGS=0

    # Give services a short moment to settle
    sleep 10
    if systemctl is-active --quiet bjorn.service; then
        log "SUCCESS" "BJORN service is running"
    else
        log "WARNING" "BJORN service is not running"
        echo -e "${YELLOW}BJORN service is not running. Check the log for details.${NC}"
        echo -e "${YELLOW}The live logs from bjorn.service can help identify the missing dependency or startup error.${NC}"
        BJORN_VERIFY_NEEDS_LOGS=1
    fi

    # Check web interface if curl or wget is available (non-fatal)
    log "INFO" "Checking web interface..."
    if command -v curl >/dev/null 2>&1; then
        if curl -s --max-time 5 http://localhost:8000 > /dev/null; then
            log "SUCCESS" "Web interface is accessible"
        else
            log "WARNING" "Web interface is not responding"
            echo -e "${YELLOW}Web interface is not responding yet. The bjorn.service logs should explain what is missing.${NC}"
            BJORN_VERIFY_NEEDS_LOGS=1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -T 5 -O - http://localhost:8000 >/dev/null; then
            log "SUCCESS" "Web interface is accessible (wget)"
        else
            log "WARNING" "Web interface is not responding (wget)"
            echo -e "${YELLOW}Web interface is not responding yet. The bjorn.service logs should explain what is missing.${NC}"
            BJORN_VERIFY_NEEDS_LOGS=1
        fi
    else
        log "WARNING" "curl/wget not found; skipping web interface check"
    fi
}

follow_bjorn_service_logs() {
    log "INFO" "Opening live logs for bjorn.service"
    echo -e "${BLUE}Opening live BJORN service logs. Press Ctrl+C to stop following them.${NC}"
    if ! journalctl -fu bjorn.service; then
        log "WARNING" "Failed to follow bjorn.service logs automatically"
        echo -e "${YELLOW}Unable to open logs automatically. Run: journalctl -fu bjorn.service${NC}"
    fi
}
