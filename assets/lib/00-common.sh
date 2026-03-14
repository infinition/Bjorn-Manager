#!/bin/bash
# BJORN Installer — Common utilities
# Sourced by install_bjorn.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging configuration
LOG_DIR="/var/log/bjorn_install"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/bjorn_install_$(date +%Y%m%d_%H%M%S).log"
VERBOSE=false

# Failure tracking arrays
declare -a failed_apt_packages=()
declare -a failed_pip_packages=()

# Global variables
BJORN_USER="bjorn"
BJORN_PATH="/home/${BJORN_USER}/Bjorn"
CURRENT_STEP=0
TOTAL_STEPS=14

# Logging function
log() {
    local level=$1
    shift
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "$message" >> "$LOG_FILE"
    if [ "$VERBOSE" = true ] || [ "$level" != "DEBUG" ]; then
        case $level in
            "ERROR") echo -e "${RED}$message${NC}" ;;
            "SUCCESS") echo -e "${GREEN}$message${NC}" ;;
            "WARNING") echo -e "${YELLOW}$message${NC}" ;;
            "INFO") echo -e "${BLUE}$message${NC}" ;;
            *) echo -e "$message" ;;
        esac
    fi
}

# Function to display progress
show_progress() {
    echo -e "${BLUE}Step $CURRENT_STEP of $TOTAL_STEPS: $1${NC}"
}

# Error handling function
handle_error() {
    local error_code=$?
    local error_message=$1
    log "ERROR" "An error occurred during: $error_message (Error code: $error_code)"
    log "ERROR" "Check the log file for details: $LOG_FILE"
    echo -e "\n${RED}An error occurred during: $error_message${NC}"
    echo -e "Check the log file for more details: $LOG_FILE"
}

# Function to check command success
check_success() {
    if [ $? -eq 0 ]; then
        log "SUCCESS" "$1"
        return 0
    else
        handle_error "$1"
        return 1
    fi
}

# Prompt helper
display_prompt() {
    echo -e "$1"
}

ensure_directory() {
    local dir="$1"
    local label="${2:-Directory}"
    if [ -d "$dir" ]; then
        log "INFO" "$label already exists: $dir"
        return 0
    fi
    if mkdir -p "$dir" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Created $label: $dir"
        return 0
    fi
    log "ERROR" "Failed to create $label: $dir"
    return 1
}

ensure_line_in_file() {
    local file="$1"
    local line="$2"
    local label="${3:-line}"
    if [ ! -f "$file" ]; then
        touch "$file" >> "$LOG_FILE" 2>&1 || true
    fi
    if grep -Fqx "$line" "$file" 2>/dev/null; then
        log "INFO" "$label already present in $file"
        return 0
    fi
    if printf '%s\n' "$line" >> "$file" 2>>"$LOG_FILE"; then
        log "SUCCESS" "Added $label to $file"
        return 0
    fi
    log "ERROR" "Failed to add $label to $file"
    return 1
}

remove_lines_matching() {
    local file="$1"
    local pattern="$2"
    local label="${3:-entries}"
    if [ ! -f "$file" ]; then
        return 0
    fi
    if grep -Eq "$pattern" "$file" 2>/dev/null; then
        if sed -i "/$pattern/d" "$file" >> "$LOG_FILE" 2>&1; then
            log "INFO" "Removed existing $label from $file"
            return 0
        fi
        log "ERROR" "Failed to remove existing $label from $file"
        return 1
    fi
    log "INFO" "No existing $label found in $file"
    return 0
}

log_file_write_action() {
    local file="$1"
    local label="${2:-file}"
    if [ -e "$file" ]; then
        log "INFO" "$label already exists at $file; updating it"
    else
        log "INFO" "Creating $label at $file"
    fi
}

ensure_service_enabled() {
    local service="$1"
    local label="${2:-$1}"
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        log "INFO" "$label is already enabled"
        return 0
    fi
    if systemctl enable "$service" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Enabled $label"
        return 0
    fi
    log "ERROR" "Failed to enable $label"
    return 1
}

start_or_restart_service() {
    local service="$1"
    local label="${2:-$1}"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        if systemctl restart "$service" >> "$LOG_FILE" 2>&1; then
            log "SUCCESS" "Restarted $label"
            return 0
        fi
        log "ERROR" "Failed to restart $label"
        return 1
    fi
    if systemctl start "$service" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Started $label"
        return 0
    fi
    log "ERROR" "Failed to start $label"
    return 1
}

# Cleanup handler (for temporary extraction directory)
cleanup() {
    if [ -n "$EXTRACT_DIR" ] && [ -d "$EXTRACT_DIR" ]; then
        log "INFO" "Cleaning up temporary files"
        rm -rf "$EXTRACT_DIR"
    fi
}

# Clean exit with recap of failures
clean_exit() {
    local exit_code=$1
    if [ $exit_code -eq 0 ]; then
        log "SUCCESS" "BJORN installation completed!"
        log "INFO" "Log file available at: $LOG_FILE"

        if [ ${#failed_apt_packages[@]} -ne 0 ]; then
            echo -e "\n${RED}The following apt packages or steps failed to complete:${NC}"
            for pkg in "${failed_apt_packages[@]}"; do
                echo "- $pkg"
            done
            echo -e "\nPlease try installing them manually using 'sudo apt-get install <package>' (or fix step)."
        fi

        if [ ${#failed_pip_packages[@]} -ne 0 ]; then
            echo -e "\n${RED}The following pip packages or steps failed to complete:${NC}"
            for pkg in "${failed_pip_packages[@]}"; do
                echo "- $pkg"
            done
            echo -e "\nTry: 'pip3 install <package>' $([ -n "$PIP_BREAK_FLAG" ] && echo "$PIP_BREAK_FLAG")"
        fi
    else
        log "ERROR" "BJORN installation encountered errors"
        log "ERROR" "See log: $LOG_FILE"
        echo -e "${RED}BJORN installation encountered errors. See: $LOG_FILE${NC}"
    fi
    exit $exit_code
}
