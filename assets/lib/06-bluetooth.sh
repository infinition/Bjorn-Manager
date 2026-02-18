#!/bin/bash
# BJORN Installer — Bluetooth PAN auto-connect service
# Sourced by install_bjorn.sh (requires 00-common.sh)

execute_bluetooth_script() {
    log "INFO" "Setting up Bluetooth auto-connect..."
    BT_SETTINGS_DIR="/home/$BJORN_USER/.settings_bjorn"
    BT_JSON="$BT_SETTINGS_DIR/bt.json"
    AUTO_BT_CONNECT_SCRIPT="/usr/local/bin/auto_bt_connect.py"
    AUTO_BT_SERVICE="/etc/systemd/system/auto_bt_connect.service"

    if mkdir -p "$BT_SETTINGS_DIR" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Created directory $BT_SETTINGS_DIR"
    else
        log "ERROR" "Failed to create directory $BT_SETTINGS_DIR"
        failed_apt_packages+=(".settings_bjorn directory creation")
        return 0
    fi

    cat > "$BT_JSON" << EOF
{
    "device_mac": "$BLUETOOTH_MAC_ADDRESS"
}
EOF
    [ $? -eq 0 ] && log "SUCCESS" "Created bt.json at $BT_JSON" || { log "ERROR" "Failed to create bt.json"; failed_apt_packages+=("bt.json creation"); return 0; }

    cat > "$AUTO_BT_CONNECT_SCRIPT" << 'EOF'
#!/usr/bin/env python3
import json, subprocess, time, logging, os
LOG_FORMAT = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
logging.basicConfig(filename="/var/log/auto_bt_connect.log", level=logging.INFO, format=LOG_FORMAT)
logger = logging.getLogger("auto_bt_connect")
CONFIG_PATH = "/home/bjorn/.settings_bjorn/bt.json"
CHECK_INTERVAL = 30

def ensure_bluetooth_service():
    try:
        res = subprocess.run(["systemctl", "is-active", "bluetooth"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if "active" not in res.stdout:
            logger.info("Bluetooth service not active. Starting and enabling it...")
            start_res = subprocess.run(["systemctl", "start", "bluetooth"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if start_res.returncode != 0:
                logger.error(f"Failed to start bluetooth service: {start_res.stderr}")
                return False
            enable_res = subprocess.run(["systemctl", "enable", "bluetooth"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if enable_res.returncode != 0:
                logger.error(f"Failed to enable bluetooth service: {enable_res.stderr}")
        return True
    except Exception as e:
        logger.error(f"Error ensuring bluetooth service: {e}")
        return False

def is_already_connected():
    ip_res = subprocess.run(["ip", "addr", "show", "bnep0"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return (ip_res.returncode == 0 and "inet " in ip_res.stdout)

def run_in_background(cmd):
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def establish_connection(device_mac):
    logger.info(f"Attempting to connect PAN with device {device_mac}...")
    bt_process = run_in_background(["bt-network", "-c", device_mac, "nap"])
    time.sleep(3)
    if bt_process.poll() is not None:
        if bt_process.returncode != 0:
            stderr_output = bt_process.stderr.read() if bt_process.stderr else ""
            logger.error(f"bt-network failed: {stderr_output}")
            return False
        else:
            logger.warning("bt-network ended immediately. PAN may not be established.")
            return False
    dh_res = subprocess.run(["dhclient", "-4", "bnep0"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    logger.info(f"dhclient bnep0: {dh_res.stdout}")
    if dh_res.returncode != 0:
        logger.error(f"dhclient failed on bnep0: {dh_res.stderr}")
        return False
    time.sleep(2)
    subprocess.run(["dhclient", "-r", "wlan0"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    subprocess.run(["dhclient", "wlan0"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    logger.info("Successfully obtained IP on bnep0. PAN connection established with clean routing.")
    return True

def load_config():
    if not os.path.exists(CONFIG_PATH):
        logger.error(f"Config file {CONFIG_PATH} not found.")
        return None
    try:
        with open(CONFIG_PATH, "r") as f:
            config = json.load(f)
        return config.get("device_mac")
    except Exception as e:
        logger.error(f"Error loading config: {e}")
        return None

def main():
    device_mac = load_config()
    if not device_mac:
        return
    while True:
        try:
            if not ensure_bluetooth_service():
                pass
            elif is_already_connected():
                pass
            else:
                establish_connection(device_mac)
        except Exception as e:
            logger.error(f"Unexpected error in main loop: {e}")
        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    main()
EOF
    [ $? -eq 0 ] && log "SUCCESS" "Created auto_bt_connect.py at $AUTO_BT_CONNECT_SCRIPT" || { log "ERROR" "Failed to create auto_bt_connect.py"; failed_apt_packages+=("auto_bt_connect.py creation"); return 0; }
    chmod +x "$AUTO_BT_CONNECT_SCRIPT" >> "$LOG_FILE" 2>&1 || { log "ERROR" "Failed to chmod auto_bt_connect.py"; failed_apt_packages+=("auto_bt_connect.py permissions"); }

    cat > "$AUTO_BT_SERVICE" << EOF
[Unit]
Description=Auto Bluetooth PAN Connect
After=network.target bluetooth.service
Wants=bluetooth.service

[Service]
Type=simple
ExecStart=$AUTO_BT_CONNECT_SCRIPT
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    [ $? -eq 0 ] && log "SUCCESS" "Created auto_bt_connect.service at $AUTO_BT_SERVICE" || { log "ERROR" "Failed to create auto_bt_connect.service"; failed_apt_packages+=("auto_bt_connect.service creation"); return 0; }

    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || { log "ERROR" "Failed to reload systemd daemon (bt)"; failed_apt_packages+=("systemd daemon reload (bt)"); }
    systemctl enable auto_bt_connect.service >> "$LOG_FILE" 2>&1 || { log "ERROR" "Failed to enable auto_bt_connect.service"; failed_apt_packages+=("auto_bt_connect.service enable"); }
    systemctl start auto_bt_connect.service >> "$LOG_FILE" 2>&1 || { log "ERROR" "Failed to start auto_bt_connect.service"; failed_apt_packages+=("auto_bt_connect.service start"); }
}
