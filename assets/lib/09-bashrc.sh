#!/bin/bash
# BJORN Installer — bashrc commands and ASCII art
# Sourced by install_bjorn.sh (requires 00-common.sh)

# Function to add bjorn commands to .bashrc
add_bjorn_commands_to_bashrc() {
    log "INFO" "Adding bjorn commands and ASCII art to .bashrc"
    read -r -d '' BORN_COMMANDS << 'EOF'


# Adding custom bjorn commands
function bjorn() {
    case "$1" in
        switcher)
            case "$2" in
                usb)         sudo /home/bjorn/.scripts_bjorn/mode-switcher.sh -usb ;;
                bluetooth)   sudo /home/bjorn/.scripts_bjorn/mode-switcher.sh -bluetooth ;;
                status)      sudo /home/bjorn/.scripts_bjorn/mode-switcher.sh -status ;;
                *)           sudo /home/bjorn/.scripts_bjorn/mode-switcher.sh ;;
            esac
            ;;
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
        usb)        sudo /home/bjorn/.scripts_bjorn/bjorn_usb_gadget.sh ;;
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
            echo "  switcher            Manage switcher modes"
            echo "      usb             Launch switcher in USB mode"
            echo "      bluetooth       Launch switcher in Bluetooth mode"
            echo "      status          Check switcher status"
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
            echo "  usb                 Execute the USB gadget script"
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
EOF

    # Append the bjorn commands to the .bashrc of the bjorn user
    echo "$BORN_COMMANDS" >> /home/$BJORN_USER/.bashrc

    # Ensure the bjorn user owns the .bashrc file
    if chown $BJORN_USER:$BJORN_USER /home/$BJORN_USER/.bashrc >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Set ownership for .bashrc"
    else
        log "ERROR" "Failed to set ownership for .bashrc"
        failed_apt_packages+=(".bashrc ownership")
    fi

    # Add ASCII art to .bashrc
    log "INFO" "Adding ASCII art to .bashrc"
    cat << 'EOF' >> /home/$BJORN_USER/.bashrc


# Display BJORN ASCII art
cat << "ARTEOF"


    @@#@                              @#@@
  @@#.*@                              @*.#@@
 @@..=@                                @=..@@
@+...@                                  @...@
@-...@#                @@                %@...-@
@*:...@                @@@@                @:..:*@
@::...@            @@@@@##@@@@@            @...::@
@.:...-@@ @@@   @@*#=-=@*#@=-=#*@@   @@@ @@-...:.@
@::.....+%@--#@@#++...:@--@:...++#@@#--@%+.....::@
@%::.....-*..%+-+=:...:@**@:...:=+-+%..*-....:::%@
 @+::::..@:-@##+=.:.:::%==@:::.:.=+##@-:@..::::+@
  @@.:::@#*@#%+:=:::::-%::%-:::::=:+%#@*#@:::.@@
    @@.=@*@@%%%@@@@@@@@@#@@@@@@@@@@%%%@@*@=.@@
     @@@@#%%%=:::-**:::@@@@:::**-:::=%%%#@@@@
       @@##****#%@@@@@@@@@@@@@@@@%#****%#@@
       @@@@@*+-::::::::::::::::::::-+*@@@@@
        @@@#..+@%.+:..........:+.%@+..#@@%
       @@*%#..@@@%@#..........#@%@@@..#%*@@
     @@@***@::+@@@@..#@#::#@#..@@@@+::@***@@@
     %@@#++-@%:.:%-:@===++===@:=%:.:%@-++#@@%
      @@##*========@@@@@@@@@@@@========*##@@
      @%@#*============================*#@%@
      @@@##=*==+==================+==*=##@@@
        @@###*=*+================+*=*###@@
         @@#@####*==*+======+*==*####@#@@
        %@@@@@%#@%####+====+####%@#%@@@@@*
        @@.:#@@@@@@%@@#*==*#@@%@@@@@@#:.@@
         @@#@@@@@@@@@@@%##%@@@@@@@@@@@#@@
             @@@@@@@@@@@@@@@@@@@@@@@%
              @@@@@@@@@@@@@@@@@@@@@@
         :::::::##:-@@======@@-:#%:::::::
       ::::::::::-==-::::::::-+=-::::::::::
        ::::::::::::::::::::::::::::::::::
ARTEOF

echo "   by Infinition - version 1.0 alpha 1"
echo "bjorn-cyberviking@outlook.com"
EOF

    log "SUCCESS" "bjorn commands and ASCII art added to .bashrc"
}
