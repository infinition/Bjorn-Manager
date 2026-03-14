#!/bin/bash
# BJORN Installer - bashrc commands and ASCII art
# Sourced by install_bjorn.sh (requires 00-common.sh)

remove_bashrc_block_by_exact_markers() {
    local file="$1"
    local start_marker="$2"
    local end_marker="$3"
    local temp_file

    temp_file=$(mktemp)
    awk -v start="$start_marker" -v end="$end_marker" '
        BEGIN { skip=0 }
        $0 == start { skip=1; next }
        skip && $0 == end { skip=0; next }
        !skip { print }
    ' "$file" > "$temp_file"
    mv "$temp_file" "$file"
}

remove_bashrc_block_by_patterns() {
    local file="$1"
    local start_pattern="$2"
    local end_pattern="$3"
    local temp_file

    temp_file=$(mktemp)
    awk -v start="$start_pattern" -v end="$end_pattern" '
        BEGIN { skip=0 }
        !skip && $0 ~ start { skip=1; next }
        skip && $0 ~ end { skip=0; next }
        !skip { print }
    ' "$file" > "$temp_file"
    mv "$temp_file" "$file"
}

# Function to add bjorn commands to .bashrc
add_bjorn_commands_to_bashrc() {
    local BASHRC_FILE="/home/$BJORN_USER/.bashrc"

    log "INFO" "Adding bjorn commands and ASCII art to .bashrc"
    touch "$BASHRC_FILE"

    read -r -d '' BORN_COMMANDS << 'EOF' || true
# BEGIN BJORN COMMANDS
# Adding custom bjorn commands
function bjorn() {
    case "$1" in
        ssid)       echo "Current SSID:"; iw dev wlan0 link | grep 'SSID' | awk '{print $2}' ;;
        fu)         sudo journalctl -fu bjorn.service ;;
        monitor)    watch -n 1 "echo 'CPU Usage:'; top -bn1 | grep 'Cpu(s)' && echo '\nMemory:'; free -h && echo '\nDisk:'; df -h /home/bjorn" ;;
        backup)     echo "Backup in progress... (functionality to be configured later)" ;;
        update)     echo "Updating... (functionality to be configured later)" ;;
        restore)    echo "Restoring... (functionality to be configured later)" ;;
        network)    echo "Network Interfaces:"; ip -br addr; echo -e "\nActive Connections:"; netstat -tuln ;;
        version)
            echo "Bjorn Version: $(cat /home/bjorn/Bjorn/version.txt 2>/dev/null || echo 'unknown')"
            echo "System: $(uname -a)"
            echo "Python: $(python3 --version 2>&1)"
            ;;
        search)
            if [ -z "$2" ]; then
                echo "Usage: bjorn search <pattern>"
            else
                grep -r "$2" /home/bjorn/Bjorn/data/logs/
            fi
            ;;
        status)     sudo systemctl status bjorn.service ;;
        start)      sudo systemctl start bjorn.service ;;
        stop)       sudo systemctl stop bjorn.service ;;
        restart)    sudo systemctl restart bjorn.service ;;
        python)
            sudo systemctl stop bjorn.service
            wait_until_service_stopped bjorn.service
            clear
            sudo python3 /home/bjorn/Bjorn/Bjorn.py
            ;;
        tail)       sudo tail -f /home/bjorn/Bjorn/data/logs/* ;;
        bt|bluetooth) sudo /home/bjorn/.scripts_bjorn/bjorn_bluetooth.sh ;;
        wifi)       sudo /home/bjorn/.scripts_bjorn/bjorn_wifi.sh ;;
        patch-wifi)
            MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
            ARCH_NOW=$(dpkg --print-architecture 2>/dev/null || uname -m)
            CACHE_DIR="/home/bjorn/.settings_bjorn/monitor_mode_patch"
            TEMP_REPO="/tmp/infinition_repo_temp_patch"
            FIRMWARE_SRC=""
            DEFAULT_ROUTE_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

            echo -e "\n=== Wi-Fi Monitor Mode Patch Repair ==="
            echo "Detected board: ${MODEL:-unknown}"
            echo "Detected arch:  ${ARCH_NOW:-unknown}"

            if [[ "$MODEL" != *"Zero 2"* && "$MODEL" != *"Pi 3"* ]]; then
                echo "This patch is only intended for Raspberry Pi Zero 2 W and Pi 3 boards."
                return 0
            fi

            if [[ "$ARCH_NOW" == "arm64" ]]; then
                echo "Warning: 64-bit OS detected. The firmware patch can be reapplied,"
                echo "but monitor mode may still remain limited depending on the kernel/userspace stack."
            fi

            if [ -d "$CACHE_DIR/brcm" ] || [ -d "$CACHE_DIR/cypress" ]; then
                FIRMWARE_SRC="$CACHE_DIR"
                echo "Using cached firmware patch from $CACHE_DIR"
            else
                echo "No cached firmware patch found. Downloading from GitHub..."
                rm -rf "$TEMP_REPO"
                if git clone --depth 1 https://github.com/infinition/infinition.git "$TEMP_REPO"; then
                    FIRMWARE_SRC="$TEMP_REPO/fixes/bjorn/monitor"
                    if [ ! -d "$FIRMWARE_SRC" ]; then
                        echo "Firmware patch directory not found in downloaded repository: $FIRMWARE_SRC"
                        rm -rf "$TEMP_REPO"
                        return 1
                    fi
                    mkdir -p "$CACHE_DIR"
                    rm -rf "$CACHE_DIR/brcm" "$CACHE_DIR/cypress"
                    if [ -d "$FIRMWARE_SRC/brcm" ]; then cp -rf "$FIRMWARE_SRC/brcm" "$CACHE_DIR/"; fi
                    if [ -d "$FIRMWARE_SRC/cypress" ]; then cp -rf "$FIRMWARE_SRC/cypress" "$CACHE_DIR/"; fi
                    chown -R bjorn:bjorn "$CACHE_DIR" 2>/dev/null || true
                    echo "Cached firmware patch in $CACHE_DIR"
                else
                    echo "Failed to download firmware patch from GitHub."
                    return 1
                fi
            fi

            echo "Reapplying firmware patch to /lib/firmware..."
            if [ -d "$FIRMWARE_SRC/brcm" ]; then
                sudo cp -rf "$FIRMWARE_SRC/brcm/"* /lib/firmware/brcm/ 2>/dev/null
            fi
            if [ -d "$FIRMWARE_SRC/cypress" ]; then
                sudo cp -rf "$FIRMWARE_SRC/cypress/"* /lib/firmware/cypress/ 2>/dev/null
            fi

            echo "Holding firmware-related packages..."
            if ! sudo apt-mark hold firmware-brcm80211 raspberrypi-kernel raspberrypi-bootloader; then
                echo "Warning: failed to hold one or more firmware/kernel packages."
            fi

            if [[ "$DEFAULT_ROUTE_IFACE" == wl* ]]; then
                echo "Skipping live brcmfmac reload to avoid dropping the current Wi-Fi session on $DEFAULT_ROUTE_IFACE."
                echo "Reboot the device to activate the patched firmware safely."
            else
                echo "Reloading brcmfmac module..."
                sudo rmmod brcmfmac_wcc 2>/dev/null || true
                sudo modprobe -r brcmfmac 2>/dev/null || true
                sudo modprobe brcmfmac 2>/dev/null || true
            fi

            rm -rf "$TEMP_REPO"
            echo "Wi-Fi monitor mode patch reapplied."
            ;;
        usb)        sudo /home/bjorn/.scripts_bjorn/bjorn_usb_gadget.sh ;;
        gadget)
            case "$2" in
                status)
                    echo -e "\n=== USB Composite Gadget Status ==="
                    echo -n "  usb-gadget.service: "; systemctl is-active usb-gadget.service 2>/dev/null || echo "unknown"
                    echo -n "  dnsmasq.service:    "; systemctl is-active dnsmasq.service 2>/dev/null || echo "unknown"
                    echo ""
                    if [ -c /dev/hidg0 ]; then echo -e "  /dev/hidg0 (keyboard): \033[0;32mREADY\033[0m"; else echo -e "  /dev/hidg0 (keyboard): \033[0;31mNOT FOUND\033[0m"; fi
                    if [ -c /dev/hidg1 ]; then echo -e "  /dev/hidg1 (mouse):    \033[0;32mREADY\033[0m"; else echo -e "  /dev/hidg1 (mouse):    \033[0;31mNOT FOUND\033[0m"; fi
                    if ip addr show usb0 2>/dev/null | grep -q "inet "; then
                        IP=$(ip addr show usb0 2>/dev/null | grep "inet " | awk '{print $2}')
                        echo -e "  usb0 (network):        \033[0;32m$IP\033[0m"
                    else
                        echo -e "  usb0 (network):        \033[0;31mDOWN\033[0m"
                    fi
                    echo ""
                    ;;
                restart)
                    echo "Restarting USB composite gadget (RNDIS + HID)..."
                    sudo systemctl restart usb-gadget.service
                    sleep 3
                    sudo systemctl restart dnsmasq.service
                    echo "Done. Checking status..."
                    bjorn gadget status
                    ;;
                stop)
                    echo "Stopping USB composite gadget..."
                    sudo systemctl stop usb-gadget.service
                    echo "Gadget stopped. Network and HID devices are down."
                    ;;
                *)
                    echo "Usage: bjorn gadget [status|restart|stop]"
                    echo "  status   Show RNDIS + HID + network status"
                    echo "  restart  Restart the full composite gadget"
                    echo "  stop     Tear down the gadget"
                    ;;
            esac
            ;;
        reboot)
            bjorn stop
            wait_until_service_stopped bjorn.service
            sudo reboot
            ;;
        shutdown)
            bjorn stop
            wait_until_service_stopped bjorn.service
            sudo shutdown now
            ;;
        -h|--help)
            echo "Usage: bjorn [option]"
            echo "Available options:"
            echo "  -h, --help          Display this help message"
            echo "  ssid                Display current SSID"
            echo "  fu                  Follow BJORN service logs"
            echo "  monitor             Monitor system resource usage"
            echo "  backup              Perform a backup (placeholder)"
            echo "  update              Perform an update (placeholder)"
            echo "  restore             Perform a restoration (placeholder)"
            echo "  network             Display network information"
            echo "  version             Display version and system information"
            echo "  search <pattern>    Search logs for a specific pattern"
            echo "  status              Display BJORN service status"
            echo "  start               Start the BJORN service"
            echo "  stop                Stop the BJORN service"
            echo "  restart             Restart the BJORN service"
            echo "  python              Stop the service and run Bjorn.py"
            echo "  tail                Display logs in real-time"
            echo "  bt, bluetooth       Execute the Bluetooth script"
            echo "  wifi                Execute the Wi-Fi script"
            echo "  patch-wifi          Reapply the cached/downloaded Wi-Fi monitor mode patch"
            echo "  usb                 Execute the USB gadget script"
            echo "  gadget              Manage USB composite gadget (RNDIS + HID)"
            echo "      status          Show gadget status (HID + network)"
            echo "      restart         Restart the full composite gadget"
            echo "      stop            Tear down the gadget"
            echo "  reboot              Stop service and reboot"
            echo "  shutdown            Stop service and power off"
            ;;
        *)
            echo -e "${RED}Unknown option. Use 'bjorn -h' to see available options.${NC}"
            ;;
    esac
}

# Function to wait until the service has stopped
function wait_until_service_stopped() {
    local service=$1
    echo -e "${YELLOW}Waiting for the service $service to stop...${NC}"
    while systemctl is-active --quiet "$service"; do
        sleep 1
    done
    echo -e "${GREEN}Service $service has stopped.${NC}"
}
# END BJORN COMMANDS
EOF

    read -r -d '' BJORN_ASCII_ART << 'EOF' || true
# BEGIN BJORN ASCII ART
# Display BJORN ASCII art
cat << "ARTEOF"
                                                           
                           ..+.                              x..                           
                         ..$&..                             ..&X..                         
                        .+&&:;                               :;&&;.                        
                      ..&&&X.                                 .$&&$..                      
                      .$&&& +                :                : &&&$.                      
                     .X&&&+:                .:.                .X&&&+.                     
                     .&&&&x.            .....;.....            .$&&&&..                    
                     ;&&&&&+.  . .   ..xxXX;:+:;XXxx..   . .  .X&&&&&.                     
                     .&$&&&&&;..&X..:x;&&&&+x$;x&&&$;x...$&..+&&&&&$&..                    
                     .x&$&&&&&+&&$.&$XX&&&&;X+++&&&&xx&$.&&&+&&&&&$&;.                     
                      .X$$$&&$;$x:;+xX&&&$$;$xX;$$&&&Xx+;:x$;&&&$$&x.                      
                       .+&$$X.+;.;;x$X$$$$$;$&$;$$$$$X$x;;.;;.$$$&;.                       
                        :.x&;:+.:.:::;;;;;;:.;.:;;;;;::::.:.+:;&+.;                        
                           . .;+++$$$$+;$$$+.;.x$$X+x$$$$+x;:. :                           
                             +;;;;x+;;:.:.........:.:;;+x;+;;+.                            
                            .;  :+xX$$$&&&&&&&&&&&&&$$$Xx+: .+.                            
                            .:  X&&: $&+&&&&&&&&&&&+&x ;&&X ..:                            
                            ..+.$&+  .: &&&&&&&&&&X :.  $&X.+..                            
                           .;+x.x&&.   ;&$.:$$X::&&.   :&&+:x+;.                           
                         ....;xX;+x$$Xx&x+Xxx+xxX;X&xX$$x++Xx;...:                         
                           .:;;xXXXXXXX$.;:..+..:;:XXXXXXXXx;;:.                           
                           .::;xXXXXXXXXxxxXXXXXxxxxxxxxxxx+;::.                           
                           ...;+x+xxxxXxXxxXxXXxxxXxxxxXx+x+;...                           
                            ; ;;;;xx+xxXxXxxxxxxxxxxxx+x+;;;;.x                            
                             +.;::;+;+xXxxxxxxxxx+xxx;;+;::;.                              
                             :  . .;;:;+;;+xxxxx+;;;;:;;.    X                             
                             .x&x. .. .:;.;+xxx+;.;:. .. .x&+.                             
                             +.x+.......   :;;;:   .......xx.                              
                               +++....................... ++                               
                                   . ................. :                                   
                                &&&&X.$Xx..;:::;..x$$.$&&&&                                
                            &&&&&&&&&&+.;$&&&&&&&$;.+&&&&&&&&&&$                           
                                         
                                                                              
ARTEOF

echo "Bjorn CyberViking "
# END BJORN ASCII ART
EOF

    if grep -Fq "# BEGIN BJORN COMMANDS" "$BASHRC_FILE" || grep -Fq "function bjorn()" "$BASHRC_FILE"; then
        log "INFO" "BJORN shell commands already exist in .bashrc; refreshing managed block"
    else
        log "INFO" "Installing BJORN shell commands into .bashrc"
    fi

    if grep -Fq "# BEGIN BJORN ASCII ART" "$BASHRC_FILE" || grep -Fq '# Display BJORN ASCII art' "$BASHRC_FILE"; then
        log "INFO" "BJORN ASCII art already exists in .bashrc; refreshing managed block"
    else
        log "INFO" "Installing BJORN ASCII art into .bashrc"
    fi

    remove_bashrc_block_by_exact_markers "$BASHRC_FILE" "# BEGIN BJORN COMMANDS" "# END BJORN COMMANDS"
    remove_bashrc_block_by_exact_markers "$BASHRC_FILE" "# BEGIN BJORN ASCII ART" "# END BJORN ASCII ART"
    remove_bashrc_block_by_patterns "$BASHRC_FILE" "^# Adding custom bjorn commands$" "^# Display BJORN ASCII art$"
    remove_bashrc_block_by_patterns "$BASHRC_FILE" '^cat << "ARTEOF"$' '^echo "bjorn-cyberviking@outlook\.com"$'

    printf '\n%s\n' "$BORN_COMMANDS" >> "$BASHRC_FILE"
    printf '\n%s\n' "$BJORN_ASCII_ART" >> "$BASHRC_FILE"

    # Ensure the bjorn user owns the .bashrc file
    if chown $BJORN_USER:$BJORN_USER "$BASHRC_FILE" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Set ownership for .bashrc"
    else
        log "ERROR" "Failed to set ownership for .bashrc"
        failed_apt_packages+=(".bashrc ownership")
    fi

    log "SUCCESS" "bjorn commands and ASCII art are configured in .bashrc"
}
