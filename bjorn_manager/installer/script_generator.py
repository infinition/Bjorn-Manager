"""Generate custom BJORN installation shell scripts from a configuration dict.

The generator produces a custom orchestrator that ``source``s the modular
``lib/*.sh`` modules already present on the device (uploaded by the SSH worker).
User-provided snippets are appended as extra steps.
"""

import os
import re
import stat
import tempfile
import time
from typing import Dict, List, Optional


class ScriptGenerator:
    """Build a custom bash installer orchestrator from an advanced-config dict."""

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    @staticmethod
    def generate(config: dict, *, git_branch: str = "main") -> str:
        """Generate a custom installation shell script from *config*.

        Parameters
        ----------
        config:
            A dict with the following keys (all optional with sensible
            defaults):

            * ``epd_version``   -- e-paper display type (str)
            * ``manual_mode``   -- boolean
            * ``bluetooth_mac`` -- MAC address string
            * ``webui_auth``    -- boolean, enable web UI auth
            * ``webui_password``-- plaintext password (str)
            * ``apt_packages``  -- list of str
            * ``pip_packages``  -- list of str
            * ``extra_apt``     -- whitespace-separated extra apt packages
            * ``extra_pip``     -- whitespace-separated extra pip packages
            * ``system_configs``-- dict of toggles (see ``_generate_system_configs``)
            * ``user_snippets`` -- list of ``{"name": str, "code": str}``

        git_branch:
            The branch (or tag) to ``git clone``.  Defaults to ``"main"``.

        Returns
        -------
        str
            Absolute path to the generated temporary ``.sh`` file.
        """
        extra_apt_list = _split_packages(config.get("extra_apt", ""))
        extra_pip_list = _split_packages(config.get("extra_pip", ""))

        apt_pkgs: List[str] = config.get("apt_packages", []) or []
        pip_pkgs: List[str] = config.get("pip_packages", []) or []

        user_snippets: List[dict] = config.get("user_snippets", []) or []

        # Build the snippets block and compute total steps.
        base_steps = 8  # steps 1-8 are fixed
        n_snippets = len(user_snippets)
        total_steps = base_steps + max(n_snippets, 1)

        snippets_block = ScriptGenerator._build_snippets_block(
            user_snippets, base_steps
        )

        system_configs = ScriptGenerator._generate_system_configs(
            config.get("system_configs", {})
        )

        script_content = _SCRIPT_TEMPLATE.format(
            timestamp=time.strftime("%Y-%m-%d %H:%M:%S"),
            total_steps=total_steps,
            epd_version=config.get("epd_version", "epd2in13_V4"),
            manual_mode="True" if config.get("manual_mode", True) else "False",
            bluetooth_mac=config.get("bluetooth_mac", "60:57:C8:47:E3:88"),
            webui_auth="true" if config.get("webui_auth", False) else "false",
            webui_password=config.get("webui_password", ""),
            apt_packages=" ".join(f'"{p}"' for p in apt_pkgs),
            pip_packages=" ".join(f'"{p}"' for p in pip_pkgs),
            extra_apt_packages=" ".join(f'"{p}"' for p in extra_apt_list),
            extra_pip_packages=" ".join(f'"{p}"' for p in extra_pip_list),
            system_configs=system_configs,
            snippets_block=snippets_block,
            git_branch=git_branch,
        )

        return _save_temp_script(script_content)

    # ------------------------------------------------------------------
    # System configuration commands
    # ------------------------------------------------------------------

    @staticmethod
    def _generate_system_configs(configs: dict) -> str:
        """Return bash commands that apply Raspberry Pi system configuration.

        Recognised keys in *configs* (all default to ``True``):

        * ``enable_spi``
        * ``enable_i2c``
        * ``enable_bluetooth``
        * ``enable_usb_gadget``
        * ``configure_wifi``
        * ``set_limits``
        """
        commands: List[str] = []

        if configs.get("enable_spi", True):
            commands.append('log "INFO" "Enabling SPI interface..."')
            commands.append(
                'raspi-config nonint do_spi 0 >> "$LOG_FILE" 2>&1 '
                '|| log "WARNING" "raspi-config SPI failed"'
            )

        if configs.get("enable_i2c", True):
            commands.append('log "INFO" "Enabling I2C interface..."')
            commands.append(
                'raspi-config nonint do_i2c 0 >> "$LOG_FILE" 2>&1 '
                '|| log "WARNING" "raspi-config I2C failed"'
            )

        if configs.get("enable_bluetooth", True):
            commands.append('log "INFO" "Enabling Bluetooth..."')
            commands.append(
                'systemctl enable bluetooth >> "$LOG_FILE" 2>&1 || true'
            )
            commands.append(
                'systemctl start bluetooth >> "$LOG_FILE" 2>&1 || true'
            )

        if configs.get("enable_usb_gadget", True):
            commands.append('log "INFO" "Configuring USB Gadget..."')
            commands.append(
                'echo "dtoverlay=dwc2" >> /boot/firmware/config.txt'
            )
            commands.append(
                'sed -i "s/rootwait/& modules-load=dwc2,g_ether/" '
                "/boot/firmware/cmdline.txt"
            )

        if configs.get("configure_wifi", True):
            commands.append(
                'log "INFO" "Configuring WiFi (preconfigured file if present)..."'
            )
            commands.append(
                "# TODO: apply /etc/NetworkManager/system-connections/"
                "preconfigured.nmconnection if exists"
            )

        if configs.get("set_limits", True):
            commands.append('log "INFO" "Setting system limits..."')
            commands.append(
                'echo "* soft nofile 65535" >> /etc/security/limits.conf'
            )
            commands.append(
                'echo "* hard nofile 65535" >> /etc/security/limits.conf'
            )

        return "\n".join(commands)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _safe_name(n: str) -> str:
        """Sanitise a user-provided snippet name for use in filenames."""
        return (
            re.sub(r"[^A-Za-z0-9_\-\. ]+", "_", (n or "snippet").strip())
            or "snippet"
        )

    @staticmethod
    def _build_snippets_block(
        snippets: List[dict], base_steps: int
    ) -> str:
        """Return the bash fragment that executes user-provided snippets."""
        if not snippets:
            idx = base_steps + 1
            return (
                "\n# No user snippets provided\n"
                f'announce_step {idx} "No user snippets provided"\n'
                'log "INFO" "No user snippets to execute"\n'
            )

        parts: List[str] = []
        for i, snippet in enumerate(snippets, start=1):
            idx = base_steps + i
            name = ScriptGenerator._safe_name(
                snippet.get("name", f"snippet_{i}")
            )
            # Escape braces so str.format() in the outer template is safe.
            code = (snippet.get("code", "") or "").replace(
                "{", "{{"
            ).replace("}", "}}")
            parts.append(
                f'\nannounce_step {idx} "Executing user snippet: {name}"\n'
                f'USER_SNIPPET_FILE="/tmp/bjorn_user_snippet_{i}.sh"\n'
                f"cat << 'USERSNIPPET_{i}' > \"$USER_SNIPPET_FILE\"\n"
                f"{code}\n"
                f"USERSNIPPET_{i}\n"
                f'chmod +x "$USER_SNIPPET_FILE"\n'
                f'if [ -s "$USER_SNIPPET_FILE" ]; then\n'
                f"    bash \"$USER_SNIPPET_FILE\" 2>&1 | tee -a \"$LOG_FILE\" "
                f"|| log \"ERROR\" \"User snippet '{name}' returned non-zero\"\n"
                f"    log \"INFO\" \"User snippet '{name}' completed\"\n"
                f"else\n"
                f"    log \"WARNING\" \"User snippet '{name}' is empty\"\n"
                f"fi\n"
                f'rm -f "$USER_SNIPPET_FILE"\n'
            )
        return "".join(parts)


# ======================================================================
# Module-private helpers
# ======================================================================


def _split_packages(raw: str) -> List[str]:
    """Split a whitespace-separated package string into a clean list."""
    if not raw:
        return []
    return [tok for tok in re.split(r"[ \t\r\n]+", raw.strip()) if tok]


def _save_temp_script(content: str) -> str:
    """Write *content* to a temporary ``.sh`` file and return the path.

    The file is created with Unix (LF) line endings and ``0755`` permissions
    on platforms that support POSIX permission bits.
    """
    clean = content.lstrip("\ufeff")
    fd, path = tempfile.mkstemp(prefix="bjorn_advanced_", suffix=".sh")
    os.close(fd)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(clean)
    try:
        os.chmod(path, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
    except OSError:
        pass  # Windows does not support full POSIX permission bits
    return path


# ======================================================================
# Bash script template — Custom orchestrator
# ======================================================================
# This template sources the lib/ modules that are already on the device
# (uploaded via SSH), then runs a custom step sequence with user overrides.
#
# Double braces ``{{`` / ``}}`` are literal braces in the output; single
# braces are ``str.format()`` placeholders.

_SCRIPT_TEMPLATE = r"""#!/bin/bash
# BJORN Custom Installation Script
# Generated by BJORN Installation Manager (Advanced Config)
# Configuration timestamp: {timestamp}
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ── Source modular lib if available, otherwise use inline fallbacks ──
SCRIPT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

if [ -d "$LIB_DIR" ]; then
    for _mod in "$LIB_DIR"/*.sh; do source "$_mod"; done
else
    # Inline fallbacks when lib/ is not present (standalone custom script)
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
    LOG_FILE="/var/log/bjorn_custom_install.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    log() {{ echo -e "[$1] $2" | tee -a "$LOG_FILE"; }}
    BJORN_USER="bjorn"
    PIP_BREAK_FLAG="--break-system-packages"
    pip_install() {{
        pip3 install $PIP_BREAK_FLAG "$@" >> "$LOG_FILE" 2>&1 || \
        pip3 install "$@" >> "$LOG_FILE" 2>&1
    }}
fi

TOTAL_STEPS={total_steps}
announce_step() {{
    local idx="$1"; local txt="$2"
    echo "Step $idx of $TOTAL_STEPS: $txt"
    log "INFO" "Step $idx/$TOTAL_STEPS: $txt"
}}

# Configuration variables
EPD_VERSION="{epd_version}"
MANUAL_MODE="{manual_mode}"
BLUETOOTH_MAC_ADDRESS="{bluetooth_mac}"
WEBUI_AUTH="{webui_auth}"
WEBUI_PASSWORD="{webui_password}"
GIT_BRANCH="{git_branch}"
NON_INTERACTIVE=1
enable_auth="$([ "{webui_auth}" = "true" ] && echo "y" || echo "n")"
WEBUI_PASSWORD_CONFIRM="$WEBUI_PASSWORD"

# Package lists
APT_PACKAGES=({apt_packages})
PIP_PACKAGES=({pip_packages})
EXTRA_APT_PACKAGES=({extra_apt_packages})
EXTRA_PIP_PACKAGES=({extra_pip_packages})

echo -e "${{YELLOW}}Starting BJORN Custom Installation${{NC}}"
log "INFO" "Installation started at $(date)"

announce_step 1 "Updating package list"
apt-get update 2>&1 | tee -a "$LOG_FILE" || log "ERROR" "apt-get update failed"

announce_step 2 "Installing base APT packages"
for pkg in "${{APT_PACKAGES[@]}}"; do
    [ -z "$pkg" ] && continue
    log "INFO" "Installing $pkg..."
    apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE" || log "ERROR" "Failed to install $pkg"
done

announce_step 3 "Installing extra APT packages (user-defined)"
if [ ${{#EXTRA_APT_PACKAGES[@]}} -gt 0 ]; then
    for pkg in "${{EXTRA_APT_PACKAGES[@]}}"; do
        [ -z "$pkg" ] && continue
        log "INFO" "Installing $pkg..."
        apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE" || log "ERROR" "Failed to install $pkg"
    done
else
    log "INFO" "No extra APT packages provided"
fi

announce_step 4 "Installing base PIP packages"
for pkg in "${{PIP_PACKAGES[@]}}"; do
    [ -z "$pkg" ] && continue
    log "INFO" "Installing $pkg..."
    pip_install "$pkg" || log "ERROR" "Failed to install $pkg"
done

announce_step 5 "Installing extra PIP packages (user-defined)"
if [ ${{#EXTRA_PIP_PACKAGES[@]}} -gt 0 ]; then
    for pkg in "${{EXTRA_PIP_PACKAGES[@]}}"; do
        [ -z "$pkg" ] && continue
        log "INFO" "Installing $pkg..."
        pip_install "$pkg" || log "ERROR" "Failed to install $pkg"
    done
else
    log "INFO" "No extra PIP packages provided"
fi

announce_step 6 "Applying system configuration"
{system_configs}

announce_step 7 "Setting up BJORN repository"
cd /home/bjorn
if [ ! -d "Bjorn" ]; then
    git clone -b {git_branch} https://github.com/infinition/Bjorn.git 2>&1 | tee -a "$LOG_FILE" || log "ERROR" "Failed to clone repo"
fi
cd Bjorn
sed -i 's/"epd_type": "epd2in13_V4"/"epd_type": "'$EPD_VERSION'"/' shared.py || true
sed -i 's/"manual_mode": True/"manual_mode": '$MANUAL_MODE'/' shared.py || true

if [ "$WEBUI_AUTH" = "true" ]; then
    announce_step 8 "Configuring Web UI authentication"
    mkdir -p /home/bjorn/.settings_bjorn
    cat > /home/bjorn/.settings_bjorn/webapp.json << WEBEOF
{{
    "username": "bjorn",
    "password": "$WEBUI_PASSWORD",
    "always_require_auth": true
}}
WEBEOF
else
    announce_step 8 "Skipping Web UI authentication"
fi

chown -R bjorn:bjorn /home/bjorn/Bjorn || true
chmod -R 755 /home/bjorn/Bjorn || true

# Use lib's setup_services if available, otherwise inline
if type setup_services &>/dev/null; then
    setup_services
else
    cat > /etc/systemd/system/bjorn.service << EOF
[Unit]
Description=Bjorn Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /home/bjorn/Bjorn/Bjorn.py
WorkingDirectory=/home/bjorn/Bjorn
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable bjorn.service
    systemctl start bjorn.service || log "ERROR" "Failed to start bjorn.service"
fi

# --- User snippets ---
{snippets_block}

log "SUCCESS" "BJORN installation completed!"
echo -e "${{GREEN}}Installation completed successfully!${{NC}}"
echo -e "${{BLUE}}Web interface will be available at: http://[device-ip]:8000${{NC}}"
"""
