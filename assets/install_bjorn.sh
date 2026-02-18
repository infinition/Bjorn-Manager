#!/bin/bash
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# BJORN Installation Script — Orchestrator
# This script sources modular lib/*.sh modules and runs the installation sequence.
# Author: infinition
# Version: 2.0 — Modular, non-interactive mode for BJORN Manager

# ── Resolve script directory ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

if [ ! -d "$LIB_DIR" ]; then
    echo -e "\033[0;31m[ERROR] lib/ directory not found at $LIB_DIR\033[0m"
    exit 1
fi

# ── Source all modules in order ─────────────────────────────────────────
for module in "$LIB_DIR"/*.sh; do
    # shellcheck disable=SC1090
    source "$module"
done

# ── Defaults for non-interactive mode ───────────────────────────────────
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
DEBUG_MODE="${DEBUG_MODE:-false}"
INSTALL_MODE="${INSTALL_MODE:-online}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PACKAGES_PATH="${PACKAGES_PATH:-bjorn_packages}"
PACKAGE_ARCHIVE="${PACKAGE_ARCHIVE:-/home/bjorn/bjorn_packages.tar.gz}"
EXTRACT_DIR=""

# Variables for Web UI authentication (can be set via env in non-interactive mode)
enable_auth="${enable_auth:-n}"
WEBUI_PASSWORD="${WEBUI_PASSWORD:-}"
WEBUI_PASSWORD_CONFIRM="${WEBUI_PASSWORD_CONFIRM:-}"
EPD_VERSION="${EPD_VERSION:-}"
MANUAL_MODE="${MANUAL_MODE:-}"
BLUETOOTH_MAC_ADDRESS="${BLUETOOTH_MAC_ADDRESS:-}"

# ── Parse command line arguments ────────────────────────────────────────
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -debug) DEBUG_MODE=true ;;
        -local)
            INSTALL_MODE="local"
            if [ ! -f "$PACKAGE_ARCHIVE" ]; then
                echo -e "${RED}Error: Package archive not found at $PACKAGE_ARCHIVE${NC}"
                exit 1
            fi
            log "INFO" "Extracting package archive: $PACKAGE_ARCHIVE"
            EXTRACT_DIR="/home/bjorn/extract"
            mkdir -p "$EXTRACT_DIR"
            if tar xzf "$PACKAGE_ARCHIVE" -C "$EXTRACT_DIR" >> "$LOG_FILE" 2>&1; then
                log "SUCCESS" "Extracted package archive"
                PACKAGES_PATH=$(find "$EXTRACT_DIR" -type d -name "bjorn_packages" -print -quit)
                if [ -z "$PACKAGES_PATH" ]; then
                    log "ERROR" "Could not find bjorn_packages directory in archive"
                    rm -rf "$EXTRACT_DIR"
                    exit 1
                fi
            else
                log "ERROR" "Failed to extract package archive"
                rm -rf "$EXTRACT_DIR"
                exit 1
            fi
            ;;
        -online) INSTALL_MODE="online" ;;
        -branch)
            shift
            GIT_BRANCH="${1:-main}"
            ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        -h|--help)
            echo -e "\nUsage: sudo ./install_bjorn.sh [options]"
            echo -e "Options:"
            echo -e "  -debug              Run the installation in debug mode"
            echo -e "  -local              Install using local package archive from /home/bjorn/"
            echo -e "  -online             Install by downloading packages (default)"
            echo -e "  -branch <name>      Git branch to clone (default: main)"
            echo -e "  --non-interactive   Skip all prompts (use env vars for config)"
            echo -e "  -h, --help          Display this help message"
            echo -e "\nNon-interactive env vars:"
            echo -e "  NON_INTERACTIVE=1   Enable non-interactive mode"
            echo -e "  EPD_VERSION         E-paper display type (e.g. epd2in13_V4)"
            echo -e "  MANUAL_MODE         True or False"
            echo -e "  enable_auth         y or n"
            echo -e "  WEBUI_PASSWORD      Web UI password (if enable_auth=y)"
            echo -e "  BLUETOOTH_MAC_ADDRESS  Bluetooth MAC address"
            echo -e "  GIT_BRANCH          Git branch to clone\n"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo -e "Use -h or --help for usage information."
            exit 1
            ;;
    esac
    shift
done

# Register cleanup trap
trap cleanup EXIT

# ── Main installation process ───────────────────────────────────────────
main() {
    log "INFO" "Starting BJORN installation..."

    # Must run as root
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}This script must be run as root. Please use 'sudo'.${NC}"
        exit 1
    fi

    echo -e "${YELLOW} BJORN by Infinition version 1.0 alpha 1${NC}"

    # ── Interactive prompts (skipped in non-interactive mode) ───────────
    if [ "$NON_INTERACTIVE" = "1" ]; then
        log "INFO" "Non-interactive mode: using environment variables for configuration"
        : "${EPD_VERSION:=epd2in13_V4}"
        : "${MANUAL_MODE:=True}"
        : "${BLUETOOTH_MAC_ADDRESS:=60:57:C8:47:E3:88}"
        : "${enable_auth:=n}"
        : "${WEBUI_PASSWORD:=}"
        WEBUI_PASSWORD_CONFIRM="$WEBUI_PASSWORD"
    else
        # E-Paper Display Selection
        echo -e "\n${BLUE}Please select your E-Paper Display version:${NC}"
        echo "1. epd2in13"
        echo "2. epd2in13_V2"
        echo "3. epd2in13_V3"
        echo "4. epd2in13_V4"
        echo "5. epd2in7"
        while true; do
            read -p "Enter your choice (1-5): " epd_choice
            case $epd_choice in
                1) EPD_VERSION="epd2in13"; break;;
                2) EPD_VERSION="epd2in13_V2"; break;;
                3) EPD_VERSION="epd2in13_V3"; break;;
                4) EPD_VERSION="epd2in13_V4"; break;;
                5) EPD_VERSION="epd2in7"; break;;
                *) echo -e "${RED}Invalid choice. Please select 1-5.${NC}";;
            esac
        done

        # Manual vs AI Mode
        echo -e "\n${BLUE}Start Bjorn in Manual Mode or AI Mode?${NC}"
        echo "1. Manual Mode (default)"
        echo "2. AI Mode"
        while true; do
            read -p "Enter your choice (1-2): " mode_choice
            case $mode_choice in
                1) MANUAL_MODE="True"; break;;
                2) MANUAL_MODE="False"; break;;
                *) echo -e "${RED}Invalid choice. Please select 1 or 2.${NC}";;
            esac
        done

        # Web UI password (optional)
        echo -e "\n${BLUE}Enable a password for the BJORN web UI?${NC}"
        read -p "Enable password protection? (y/n): " enable_auth
        if [[ "$enable_auth" =~ ^[Yy]$ ]]; then
            while true; do
                read -s -p "Enter password: " WEBUI_PASSWORD
                echo
                read -s -p "Confirm password: " WEBUI_PASSWORD_CONFIRM
                echo
                if [ "$WEBUI_PASSWORD" != "$WEBUI_PASSWORD_CONFIRM" ]; then
                    echo -e "${RED}Passwords do not match. Try again.${NC}"
                elif [ -z "$WEBUI_PASSWORD" ]; then
                    echo -e "${RED}Password cannot be empty. Try again.${NC}"
                else
                    break
                fi
            done
        fi

        # Bluetooth MAC (optional, with default)
        echo -e "\n${BLUE}Bluetooth PAN device MAC (e.g., 60:57:C8:47:E3:88)${NC}"
        read -p "Enter MAC (leave empty for default): " BLUETOOTH_MAC_ADDRESS
        if [ -z "$BLUETOOTH_MAC_ADDRESS" ]; then
            BLUETOOTH_MAC_ADDRESS="60:57:C8:47:E3:88"
        fi
    fi

    log "INFO" "Selected EPD: $EPD_VERSION"
    log "INFO" "Selected mode: $( [ "$MANUAL_MODE" = "True" ] && echo "Manual" || echo "AI" )"
    log "INFO" "Git branch: $GIT_BRANCH"

    # ── Installation steps ──────────────────────────────────────────────
    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Checking system compatibility"
    check_system_compatibility

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Installing system dependencies"
    install_dependencies

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Managing Wi-Fi connections"
    manage_wifi_connections

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Configuring system limits"
    configure_system_limits

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Configuring interfaces"
    configure_interfaces

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Setting up BJORN"
    setup_bjorn

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Setting up Web UI authentication"
    setup_webui_auth

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Creating scripts directory"
    create_scripts_directory

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Setting up Scripts in scripts directory"
    setup_bjorn_scripts

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Installing Bluetooth & USB gadget services"
    execute_bluetooth_script
    execute_usb_gadget_script

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Setting up services"
    setup_services

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Verifying installation"
    verify_installation

    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress "Adding bjorn commands to .bashrc"
    add_bjorn_commands_to_bashrc

    # Remove git files (non-fatal)
    if [ "$DEBUG_MODE" = false ]; then
        find "$BJORN_PATH" -name ".git*" -exec rm -rf {} + >> "$LOG_FILE" 2>&1 \
            && log "SUCCESS" "Removed git files from Bjorn directory" \
            || log "WARNING" "Failed to remove some git files from Bjorn directory"
    fi

    log "SUCCESS" "BJORN installation completed!"
    log "INFO" "Please reboot your system to apply all changes."
    echo -e "\n${GREEN}Installation completed successfully!${NC}"
    echo "1. Ensure your e-Paper HAT is connected"
    echo "2. Web UI: http://[device-ip]:8000"

    if [ "$NON_INTERACTIVE" = "1" ]; then
        log "INFO" "Non-interactive mode: skipping reboot prompt"
    else
        read -p "Reboot now? (y/n): " reboot_now
        if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
            if reboot >> "$LOG_FILE" 2>&1; then
                log "INFO" "System reboot initiated."
            else
                log "ERROR" "Failed to initiate reboot."
                echo -e "${RED}Failed to initiate reboot. Check the log for details.${NC}"
            fi
        else
            echo -e "${YELLOW}Reboot to apply all changes & run BJORN service.${NC}"
        fi
    fi

    clean_exit 0
}

main
