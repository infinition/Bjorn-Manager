#!/bin/bash
# BJORN Installer — System configuration (limits, interfaces, wifi)
# Sourced by install_bjorn.sh (requires 00-common.sh)

# Function to configure system limits
configure_system_limits() {
    log "INFO" "Configuring system limits..."

    ensure_line_in_file /etc/security/limits.conf "* soft nofile 65535" "soft nofile limit" || failed_apt_packages+=("limits.conf soft nofile")
    ensure_line_in_file /etc/security/limits.conf "* hard nofile 65535" "hard nofile limit" || failed_apt_packages+=("limits.conf hard nofile")
    ensure_line_in_file /etc/security/limits.conf "root soft nofile 65535" "root soft nofile limit" || failed_apt_packages+=("limits.conf root soft nofile")
    ensure_line_in_file /etc/security/limits.conf "root hard nofile 65535" "root hard nofile limit" || failed_apt_packages+=("limits.conf root hard nofile")

    remove_lines_matching /etc/systemd/system.conf '^#?DefaultLimitNOFILE=' "DefaultLimitNOFILE entries" || failed_apt_packages+=("system.conf DefaultLimitNOFILE cleanup")
    ensure_line_in_file /etc/systemd/system.conf "DefaultLimitNOFILE=65535" "DefaultLimitNOFILE setting" || failed_apt_packages+=("system.conf DefaultLimitNOFILE")

    remove_lines_matching /etc/systemd/user.conf '^#?DefaultLimitNOFILE=' "DefaultLimitNOFILE entries" || failed_apt_packages+=("user.conf DefaultLimitNOFILE cleanup")
    ensure_line_in_file /etc/systemd/user.conf "DefaultLimitNOFILE=65535" "DefaultLimitNOFILE setting" || failed_apt_packages+=("user.conf DefaultLimitNOFILE")

    log_file_write_action /etc/security/limits.d/90-nofile.conf "nofile limits drop-in"
    cat > /etc/security/limits.d/90-nofile.conf << EOF
root soft nofile 65535
root hard nofile 65535
EOF
    ensure_line_in_file /etc/sysctl.conf "fs.file-max = 2097152" "fs.file-max setting" || failed_apt_packages+=("sysctl fs.file-max")
    if sysctl -p >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" "Configured sysctl settings"
    else
        log "ERROR" "Failed to configure sysctl settings"
        echo -e "${RED}Failed to configure sysctl settings. Check the log for details.${NC}"
        failed_apt_packages+=("sysctl configuration")
    fi
    log "SUCCESS" "System limits configuration completed"
}

# Configure SPI and I2C
configure_interfaces() {
    log "INFO" "Configuring SPI and I2C interfaces..."

    # Enable SPI and I2C using raspi-config
    raspi-config nonint do_spi 0
    raspi-config nonint do_i2c 0

    check_success "Interface configuration completed"
}

# Function to manage Wi-Fi connections
# Supports two persistence models:
#   - Legacy: /etc/NetworkManager/system-connections/preconfigured.nmconnection
#   - Trixie+: netplan manages Wi-Fi via /etc/netplan/*.yaml
manage_wifi_connections() {
    log "INFO" "Managing Wi-Fi connections..."

    PRECONFIG_FILE="/etc/NetworkManager/system-connections/preconfigured.nmconnection"

    # ── Branch 1: Netplan-managed Wi-Fi (Trixie / Debian 13+) ────────
    # On these images, Wi-Fi persistence lives in /etc/netplan/*.yaml and
    # NM keyfiles under /run/ are generated at runtime. There is no
    # preconfigured.nmconnection to migrate — touching anything here
    # risks losing Wi-Fi after reboot.
    local netplan_wifi_detected=0
    if [ -d /etc/netplan ]; then
        for yf in /etc/netplan/*.yaml; do
            [ -f "$yf" ] || continue
            if grep -q 'wifis:' "$yf" 2>/dev/null; then
                netplan_wifi_detected=1
                break
            fi
        done
    fi

    if [ "$netplan_wifi_detected" -eq 1 ]; then
        log "INFO" "Wi-Fi is managed by netplan (/etc/netplan/*.yaml). No migration needed."
        log "INFO" "Skipping legacy preconfigured.nmconnection migration on this image."
        return 0
    fi

    # ── Branch 2: Legacy preconfigured.nmconnection ──────────────────
    if [ -f "$PRECONFIG_FILE" ]; then
        log "INFO" "Extracting data from preconfigured Wi-Fi connection..."
        local migration_ok=0
        local backup_file=""
        local SSID=""
        local TEMP_FILE=""
        local CURRENT_ID=""

        SSID=$(awk -F= '
            /^\[wifi\]$/ { in_wifi=1; next }
            /^\[/ { in_wifi=0 }
            in_wifi && $1=="ssid" { print substr($0, index($0, "=") + 1); exit }
        ' "$PRECONFIG_FILE")

        if [ -z "$SSID" ]; then
            log "ERROR" "SSID not found in preconfigured file."
            echo -e "${RED}SSID not found in preconfigured Wi-Fi file. Check the log for details.${NC}"
            failed_apt_packages+=("SSID extraction from preconfigured Wi-Fi")
            return 0
        fi

        CURRENT_ID=$(awk -F= '
            /^\[connection\]$/ { in_connection=1; next }
            /^\[/ { in_connection=0 }
            in_connection && $1=="id" { print substr($0, index($0, "=") + 1); exit }
        ' "$PRECONFIG_FILE")
        TEMP_FILE="$(mktemp)"

        if [ "$CURRENT_ID" = "$SSID" ]; then
            log "INFO" "Persistent Wi-Fi profile already uses the real SSID name: $SSID"
            chmod 600 "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || true
            chown root:root "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || true
            if command -v nmcli >/dev/null 2>&1; then
                nmcli connection load "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || nmcli connection reload >> "$LOG_FILE" 2>&1 || true
            fi
            return 0
        fi

        log "INFO" "Preparing in-place rename from '${CURRENT_ID:-preconfigured}' to '$SSID'"
        if command -v nmcli >/dev/null 2>&1; then
            nmcli connection reload >> "$LOG_FILE" 2>&1 || true
            if python3 - "$PRECONFIG_FILE" "$TEMP_FILE" "$SSID" << 'PYEOF' >> "$LOG_FILE" 2>&1
import configparser
import sys

src, dst, ssid = sys.argv[1:]
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
if not cfg.read(src, encoding="utf-8"):
    raise SystemExit(1)

cfg.setdefault("connection", {})
cfg["connection"]["id"] = ssid
cfg["connection"]["type"] = cfg["connection"].get("type", "wifi")
cfg["connection"]["autoconnect"] = cfg["connection"].get("autoconnect", "true")

cfg.setdefault("wifi", {})
cfg["wifi"]["ssid"] = ssid

with open(dst, "w", encoding="utf-8") as fh:
    cfg.write(fh, space_around_delimiters=False)
PYEOF
            then
                backup_file="${PRECONFIG_FILE}.bjorn-backup-$(date +%Y%m%d_%H%M%S)"
                if cp -p "$PRECONFIG_FILE" "$backup_file" >> "$LOG_FILE" 2>&1; then
                    log "INFO" "Backed up persistent Wi-Fi profile to $backup_file"
                else
                    log "WARNING" "Failed to back up preconfigured Wi-Fi profile before in-place rename"
                fi

                if cp "$TEMP_FILE" "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1; then
                    chmod 600 "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || true
                    chown root:root "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || true
                    nmcli connection load "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || nmcli connection reload >> "$LOG_FILE" 2>&1 || true

                    if nmcli -t -f NAME connection show | grep -Fxq "$SSID"; then
                        migration_ok=1
                        log "SUCCESS" "Renamed persistent Wi-Fi profile to real SSID: $SSID"
                        log "INFO" "The file remains at $PRECONFIG_FILE for persistence."
                    else
                        log "WARNING" "NetworkManager did not verify the renamed persistent profile for SSID: $SSID. Restoring backup."
                        if [ -f "$backup_file" ]; then
                            cp "$backup_file" "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || true
                            chmod 600 "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || true
                            chown root:root "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || true
                            nmcli connection load "$PRECONFIG_FILE" >> "$LOG_FILE" 2>&1 || nmcli connection reload >> "$LOG_FILE" 2>&1 || true
                        fi
                    fi
                else
                    log "WARNING" "Failed to rewrite persistent Wi-Fi profile in place. Keeping preconfigured profile as fallback."
                fi
            else
                log "WARNING" "Failed to build migrated Wi-Fi keyfile for SSID: $SSID. Keeping preconfigured profile as fallback."
            fi
        else
            log "WARNING" "NetworkManager (nmcli) not available; skipping Wi-Fi nmcli configuration and keeping preconfigured profile"
        fi

        if [ "$migration_ok" -ne 1 ]; then
            log "WARNING" "Preconfigured Wi-Fi file was kept unchanged to avoid losing Wi-Fi after reboot."
        fi

        [ -n "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
        return 0
    fi

    # ── Branch 3: Nothing to migrate ─────────────────────────────────
    log "INFO" "No preconfigured Wi-Fi connection file found and no netplan Wi-Fi detected. Nothing to migrate."
}

# ── Auto-connect to open Wi-Fi networks ──────────────────────────────
# Installs a script + systemd timer/service OR dispatcher that
# automatically connects to open (no-password) Wi-Fi networks when no
# connection is active.
#
# Configuration file: /etc/bjorn/open-wifi.conf
#   MODE=scan        (default) timer-based periodic scan
#   MODE=dispatcher  NM dispatcher reacts to connectivity loss
#   ENABLED=1|0      master switch
#   SCAN_INTERVAL=60 seconds between scans (scan mode only)
#   MIN_SIGNAL=20    minimum signal strength (0-100) to consider
#   BLACKLIST=       comma-separated SSIDs to never connect to

setup_bjorn_open_wifi() {
    log "INFO" "Setting up auto-open-wifi service..."

    local CONF_DIR="/etc/bjorn"
    local CONF_FILE="$CONF_DIR/open-wifi.conf"
    local SCRIPT_FILE="/usr/local/bin/bjorn-open-wifi"
    local SERVICE_FILE="/etc/systemd/system/bjorn-open-wifi.service"
    local TIMER_FILE="/etc/systemd/system/bjorn-open-wifi.timer"
    local DISPATCHER_FILE="/etc/NetworkManager/dispatcher.d/99-bjorn-open-wifi"

    ensure_directory "$CONF_DIR" "BJORN config directory"

    # ── Configuration file ───────────────────────────────────────────
    if [ ! -f "$CONF_FILE" ]; then
        log_file_write_action "$CONF_FILE" "open-wifi configuration"
        cat > "$CONF_FILE" << 'CONFEOF'
# BJORN Auto Open Wi-Fi Configuration
# MODE: scan (timer-based periodic scan) or dispatcher (NM event-driven)
MODE=scan
# Master switch: 1=enabled, 0=disabled (use 'bjorn open-wifi enable' to activate)
ENABLED=0
# Seconds between scans (scan mode only)
SCAN_INTERVAL=60
# Minimum signal strength 0-100 (reject weak networks)
MIN_SIGNAL=20
# Comma-separated SSIDs to never auto-connect to (e.g. "CaptivePortal,Evil Twin")
BLACKLIST=
CONFEOF
        chmod 644 "$CONF_FILE"
        log "SUCCESS" "Created open-wifi configuration at $CONF_FILE"
    else
        log "INFO" "open-wifi configuration already exists at $CONF_FILE"
    fi

    # ── Main scanner script ──────────────────────────────────────────
    log_file_write_action "$SCRIPT_FILE" "open-wifi scanner script"
    cat > "$SCRIPT_FILE" << 'SCRIPTEOF'
#!/bin/bash
# bjorn-open-wifi — auto-connect to the strongest open Wi-Fi network
# Called by systemd timer (scan mode) or NM dispatcher (dispatcher mode).

set -euo pipefail

CONF="/etc/bjorn/open-wifi.conf"
[ -f "$CONF" ] && . "$CONF"

ENABLED="${ENABLED:-1}"
MIN_SIGNAL="${MIN_SIGNAL:-20}"
BLACKLIST="${BLACKLIST:-}"

[ "$ENABLED" != "1" ] && exit 0

# Require nmcli
command -v nmcli >/dev/null 2>&1 || exit 0

# If already connected to Wi-Fi, nothing to do
ACTIVE_WIFI=$(nmcli -t -f TYPE,STATE device status 2>/dev/null | grep '^wifi:connected' || true)
if [ -n "$ACTIVE_WIFI" ]; then
    exit 0
fi

# Build blacklist array
IFS=',' read -ra BL_ARRAY <<< "$BLACKLIST"
is_blacklisted() {
    local ssid="$1"
    local bl
    for bl in "${BL_ARRAY[@]}"; do
        bl=$(echo "$bl" | xargs)  # trim whitespace
        [ -z "$bl" ] && continue
        [ "$ssid" = "$bl" ] && return 0
    done
    return 1
}

# Trigger a fresh scan (non-blocking, best effort)
nmcli device wifi rescan 2>/dev/null || true
sleep 2

# List open networks sorted by signal strength (strongest first)
# Fields: SIGNAL:SSID:SECURITY
BEST_SSID=""
BEST_SIGNAL=0

while IFS=: read -r signal ssid security; do
    # Skip secured networks
    [ -n "$security" ] && [[ "$security" != "--" ]] && [[ "$security" != "" ]] && continue
    # Skip empty SSIDs (hidden networks)
    [ -z "$ssid" ] && continue
    # Skip below minimum signal
    [ "$signal" -lt "$MIN_SIGNAL" ] 2>/dev/null && continue
    # Skip blacklisted
    is_blacklisted "$ssid" && continue
    # Pick strongest
    if [ "$signal" -gt "$BEST_SIGNAL" ] 2>/dev/null; then
        BEST_SIGNAL="$signal"
        BEST_SSID="$ssid"
    fi
done < <(nmcli -t -f SIGNAL,SSID,SECURITY device wifi list 2>/dev/null | sort -t: -k1 -rn)

if [ -z "$BEST_SSID" ]; then
    logger -t bjorn-open-wifi "No suitable open Wi-Fi network found"
    exit 0
fi

logger -t bjorn-open-wifi "Connecting to open network '$BEST_SSID' (signal: $BEST_SIGNAL%)"

# Check if we already have a profile for this SSID
if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$BEST_SSID"; then
    nmcli connection up "$BEST_SSID" 2>/dev/null && \
        logger -t bjorn-open-wifi "Connected to '$BEST_SSID' using existing profile" || \
        logger -t bjorn-open-wifi "Failed to connect to '$BEST_SSID' using existing profile"
else
    nmcli device wifi connect "$BEST_SSID" 2>/dev/null && \
        logger -t bjorn-open-wifi "Connected to '$BEST_SSID' (new profile created)" || \
        logger -t bjorn-open-wifi "Failed to connect to '$BEST_SSID'"
fi
SCRIPTEOF
    chmod 755 "$SCRIPT_FILE"
    log "SUCCESS" "Installed open-wifi scanner script at $SCRIPT_FILE"

    # ── Systemd service (for timer mode) ─────────────────────────────
    log_file_write_action "$SERVICE_FILE" "open-wifi systemd service"
    cat > "$SERVICE_FILE" << 'SVCEOF'
[Unit]
Description=BJORN Auto Open Wi-Fi Scanner
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bjorn-open-wifi
SVCEOF
    log "SUCCESS" "Created open-wifi systemd service"

    log_file_write_action "$TIMER_FILE" "open-wifi systemd timer"
    cat > "$TIMER_FILE" << 'TMREOF'
[Unit]
Description=BJORN Auto Open Wi-Fi Scanner Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
RandomizedDelaySec=10s

[Install]
WantedBy=timers.target
TMREOF
    log "SUCCESS" "Created open-wifi systemd timer"

    # ── NM dispatcher script (for dispatcher mode) ───────────────────
    log_file_write_action "$DISPATCHER_FILE" "open-wifi NM dispatcher"
    cat > "$DISPATCHER_FILE" << 'DISPEOF'
#!/bin/bash
# NM dispatcher: trigger open-wifi scan when connectivity is lost
# Only active when MODE=dispatcher in /etc/bjorn/open-wifi.conf

CONF="/etc/bjorn/open-wifi.conf"
[ -f "$CONF" ] && . "$CONF"

[ "${ENABLED:-1}" != "1" ] && exit 0
[ "${MODE:-scan}" != "dispatcher" ] && exit 0

IFACE="$1"
ACTION="$2"

case "$ACTION" in
    connectivity-change)
        CONN_STATE=$(nmcli -t -f CONNECTIVITY general status 2>/dev/null || echo "unknown")
        if [ "$CONN_STATE" = "none" ] || [ "$CONN_STATE" = "limited" ]; then
            /usr/local/bin/bjorn-open-wifi &
        fi
        ;;
esac
DISPEOF
    chmod 755 "$DISPATCHER_FILE"
    log "SUCCESS" "Created open-wifi NM dispatcher"

    # ── Register units but do NOT start ──────────────────────────────
    # The user activates the service manually via: bjorn open-wifi enable
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
    log "INFO" "Open Wi-Fi service installed but NOT started. Use 'bjorn open-wifi enable' to activate."

    log "SUCCESS" "Auto open Wi-Fi service setup completed"
}
