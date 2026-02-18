#!/bin/bash
# BJORN Installer — Installation verification
# Sourced by install_bjorn.sh (requires 00-common.sh)

# Verify installation (non-fatal checks)
verify_installation() {
    log "INFO" "Verifying installation..."

    # Give services a moment to settle
    sleep 15
    if systemctl is-active --quiet bjorn.service; then
        log "SUCCESS" "BJORN service is running"
    else
        log "WARNING" "BJORN service is not running"
        echo -e "${YELLOW}BJORN service is not running. Check the log for details.${NC}"
    fi

    # Check web interface if curl or wget is available (non-fatal)
    log "INFO" "Checking web interface... (this may take ~45s)"
    sleep 45
    if command -v curl >/dev/null 2>&1; then
        if curl -s http://localhost:8000 > /dev/null; then
            log "SUCCESS" "Web interface is accessible"
        else
            log "WARNING" "Web interface is not responding"
            echo -e "${YELLOW}Web interface is not responding. Check the log for details.${NC}"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -O - http://localhost:8000 >/dev/null; then
            log "SUCCESS" "Web interface is accessible (wget)"
        else
            log "WARNING" "Web interface is not responding (wget)"
            echo -e "${YELLOW}Web interface is not responding. Check the log for details.${NC}"
        fi
    else
        log "WARNING" "curl/wget not found; skipping web interface check"
    fi
}
