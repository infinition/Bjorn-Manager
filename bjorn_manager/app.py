# -*- coding: utf-8 -*-
"""
BJORN CyberViking — Installation Manager
Main application: BJORNWebAPI + pywebview launcher.
"""

import sys
import os
import re
import time
import json
import threading
import pathlib
import tempfile
import base64
import logging

import webview

from bjorn_manager.ui.js_bridge import JSBridge
from bjorn_manager.ssh.config import SSHConfig
from bjorn_manager.ssh.worker import SSHWorker
from bjorn_manager.discovery.manager import Discovery
from bjorn_manager.installer.validator import ScriptValidator
from bjorn_manager.installer.script_generator import ScriptGenerator

# ── Constants ────────────────────────────────────────────────────────────────

APP_TITLE = "BJORN CyberViking — Installation Manager"
DEFAULT_USER = "bjorn"
DEFAULT_PORT = 22
EXTERNAL_HTML_FILENAME = "bjorn_ui.html"

INSTALL_SH_FALLBACK = """#!/usr/bin/env bash
echo -e "\\033[0;34m[INFO] Placeholder install_bjorn.sh (replace with real script).\\033[0m"
exit 0
"""

# Silence pywebview logger
webview.logger.handlers.clear()
webview.logger.propagate = False
webview.logger.setLevel(logging.CRITICAL + 1)
webview.logger.disabled = True


# ── BJORNWebAPI ──────────────────────────────────────────────────────────────

class BJORNWebAPI:
    def __init__(self):
        self.ssh_worker: SSHWorker | None = None
        self.discovery: Discovery | None = None
        self.window = None
        self.js = JSBridge()

        self._connected = False
        self._connected_ip: str | None = None
        self._installation_mode = False
        self._log_stream_thread: threading.Thread | None = None
        self._log_stream_stop = threading.Event()
        self._custom_script_path: str | None = None
        self._prefs_lock = threading.Lock()
        self._prefs_path = self._resolve_prefs_path()
        self._legacy_prefs_path = pathlib.Path.home() / ".bjorn_manager" / "preferences.json"
        self._registry_base = r"Software\BJORNManager"

    # ── Window lifecycle ─────────────────────────────────────────────────

    def set_window(self, window):
        self.window = window
        self.js.set_window(window)

    def on_loaded(self):
        """Called by window.events.loaded — the window is truly ready."""
        self.js.mark_ready()
        self.start_discovery()

    def close_window(self):
        try:
            if self.ssh_worker:
                self.ssh_worker.close()
            if self.discovery:
                self.discovery.stop()
            self.js.stop()
            if self.window:
                self.window.destroy()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def toggle_fullscreen(self):
        try:
            if self.window:
                self.window.toggle_fullscreen()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def get_default_ssh_key_path(self):
        home_ssh = pathlib.Path(os.path.expanduser("~")) / ".ssh"
        for name in ("id_ed25519", "id_rsa", "id_ecdsa"):
            p = home_ssh / name
            if p.exists():
                return str(p)
        return str(home_ssh / "id_ed25519")

    def get_language(self):
        try:
            lang = None
            if sys.platform == "win32":
                lang = self._read_registry_language()
            if not lang:
                prefs = self._read_prefs()
                lang = prefs.get("language")
            if not lang:
                lang = "en"
            return {"success": True, "language": lang}
        except Exception as e:
            return {"success": False, "error": str(e), "language": "en"}

    def set_language(self, language: str):
        try:
            allowed = {"en", "fr", "it", "es", "de", "zh", "ru"}
            lang = (language or "en").strip().lower()
            if lang not in allowed:
                lang = "en"
            stored = False
            if sys.platform == "win32":
                stored = self._write_registry_language(lang) or stored
            prefs = self._read_prefs()
            prefs["language"] = lang
            self._write_prefs(prefs)
            stored = True
            if not stored:
                return {"success": False, "error": "Failed to store language preference"}
            return {"success": True, "language": lang}
        except Exception as e:
            return {"success": False, "error": str(e)}

    # ── Internal callback from SSHWorker / Discovery → JS ────────────────

    def _api_callback(self, event_type: str, *args):
        if event_type == "log":
            message, level = args
            self.js.call("logMessage", message, level)
        elif event_type == "progress":
            current, total, text = args
            self.js.call("updateProgress", current, total, text)
        elif event_type == "device_found":
            label, ip = args[0], args[1]
            has_webapp = args[2] if len(args) > 2 else False
            self.js.call("addDevice", label, ip, has_webapp)
        elif event_type == "device_gone":
            # Keep discovered devices visible across scan cycles.
            # We intentionally ignore transient "gone" signals here.
            return
        elif event_type == "webapp_status":
            ip, status = args
            status_js = "true" if status else "false"
            self.js.call_raw(f"""
            (function(){{
                var dc=document.querySelector('[data-ip="{ip}"]');
                if(!dc) return;
                var icon=dc.querySelector('.webapp-icon');
                if({status_js}){{
                    if(!icon){{
                        dc.innerHTML+='<img src="https://i.postimg.cc/bwN9ScGQ/Chat-GPT-Image-21-ao-t-2025-23-04-20.png" class="webapp-icon" onclick="openWebapp(\\'{ip}\\')" title="Open WebUI">';
                    }}
                }} else {{
                    if(icon) icon.remove();
                }}
            }})()""")

    # ── Discovery ────────────────────────────────────────────────────────

    def start_discovery(self):
        try:
            if self.discovery:
                self.discovery.stop()
            self.discovery = Discovery(self._api_callback)
            self.discovery.start()
            self.js.call("logMessage", "Network discovery started", "info")
            return {"success": True}
        except Exception as e:
            self.js.call("logMessage", f"Discovery failed: {e}", "error")
            return {"success": False, "error": str(e)}

    # ── SSH connect/disconnect ───────────────────────────────────────────

    def connect_ssh(self, config):
        try:
            if self.ssh_worker:
                self.ssh_worker.close()

            ssh_config = SSHConfig(
                host=config["host"],
                port=config["port"],
                user=config["user"],
                password=config.get("password"),
                key_path=config.get("privateKeyPath") if config.get("usePrivateKey") else None,
            )

            def connect_thread():
                try:
                    self.ssh_worker = SSHWorker(ssh_config, self._api_callback)
                    success = self.ssh_worker.connect()
                    if success:
                        self._connected = True
                        self._connected_ip = config["host"]
                        # Stop discovery — not needed while connected
                        if self.discovery:
                            self.discovery.stop()
                        self.js.call("setConnectionStatus", True, config["host"])
                    else:
                        self._connected = False
                        self.js.call("setConnectionStatus", False, "")
                except Exception as e:
                    self.js.call("logMessage", f"Connection error: {e}", "error")
                    self.js.call("setConnectionStatus", False, "")

            threading.Thread(target=connect_thread, daemon=True).start()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def disconnect_ssh(self):
        try:
            # Stop log stream first
            self._log_stream_stop.set()

            if self.ssh_worker:
                self.ssh_worker.close()
                self.ssh_worker = None
            if self._custom_script_path:
                try:
                    os.unlink(self._custom_script_path)
                    self._custom_script_path = None
                except Exception:
                    pass
            self._connected = False
            self._connected_ip = None
            self._installation_mode = False
            self.js.call("setConnectionStatus", False, "")
            self.js.call("setInstallationMode", False)

            # Reset discovery instead of destroy+recreate
            if self.discovery:
                self.discovery.reset()
            else:
                self.start_discovery()
            self.js.call("logMessage", "Periodic discovery restarted", "info")
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    # ── File upload ──────────────────────────────────────────────────────

    def upload_files(self, mode, file_data=None):
        try:
            if not self.ssh_worker or not self.ssh_worker._connected:
                return {"success": False, "error": "Not connected to SSH"}
            self.js.call("logMessage", f"Starting upload in {mode} mode...", "info")

            def upload_thread():
                try:
                    if mode == "local" and file_data:
                        temp_file = self._save_temp_file(file_data, "bjorn_packages.tar.gz")
                        self.ssh_worker.upload_file(temp_file, "/home/bjorn/bjorn_packages.tar.gz")
                        os.unlink(temp_file)
                    elif mode == "debug" and file_data:
                        temp_file = self._save_temp_file(file_data, "Bjorn.zip")
                        self.ssh_worker.deploy_bjorn_zip(temp_file)
                        os.unlink(temp_file)
                    self.js.call("logMessage", "Upload completed successfully", "success")
                except Exception as e:
                    self.js.call("logMessage", f"Upload failed: {e}", "error")

            threading.Thread(target=upload_thread, daemon=True).start()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def upload_custom_script(self, file_data: str, filename: str):
        try:
            self.js.call("logMessage", f"Uploading custom script: {filename}", "info")
            temp_file = self._save_temp_file(file_data, filename)
            if not ScriptValidator.validate(temp_file):
                os.unlink(temp_file)
                return {"success": False, "error": "Invalid shell script format"}
            self._custom_script_path = temp_file
            self.js.call("logMessage", f"Custom script uploaded: {filename}", "success")
            return {"success": True}
        except Exception as e:
            self.js.call("logMessage", f"Custom script upload failed: {e}", "error")
            return {"success": False, "error": str(e)}

    # ── Installation ─────────────────────────────────────────────────────

    def install_bjorn(self, config):
        try:
            if not self.ssh_worker or not self.ssh_worker._connected:
                return {"success": False, "error": "Not connected to SSH"}
            self._installation_mode = True
            self.js.call("setInstallationMode", True)

            def install_thread():
                try:
                    if config.get("useCustomScript") and self._custom_script_path:
                        script_local = self._custom_script_path
                        script_name = f"custom_install_{int(time.time())}.sh"
                        self.js.call("logMessage", "Using custom installation script", "info")
                        script_remote = f"/home/bjorn/{script_name}"
                        self.ssh_worker.upload_file(script_local, script_remote)
                    else:
                        assets_dir = self._get_assets_dir()
                        self.js.call("logMessage", "Uploading modular install scripts...", "info")
                        script_remote = self.ssh_worker.upload_install_scripts(assets_dir)
                        self.js.call("logMessage", "Using default installation script", "info")

                    params = {
                        "epd_choice": config.get("epdChoice", 4),
                        "manual_mode": config.get("operationMode") == "manual",
                        "webui_enable_auth": config.get("enableWebAuth", False),
                        "webui_password": config.get("webPassword", ""),
                        "bt_mac": config.get("bluetoothMac", "60:57:C8:47:E3:88"),
                        "install_mode": config.get("installMode", "online"),
                        "git_branch": config.get("gitBranch", "main"),
                    }
                    if config.get("customScriptDesc"):
                        self.js.call("logMessage", f'Script desc: {config["customScriptDesc"]}', "info")

                    success = self.ssh_worker.run_install(script_remote, params, False)
                    if success:
                        self.js.call("logMessage", "BJORN installation completed successfully!", "success")
                    else:
                        self.js.call("logMessage", "BJORN installation failed", "error")

                    if config.get("useCustomScript") and self._custom_script_path:
                        try:
                            os.unlink(self._custom_script_path)
                            self._custom_script_path = None
                        except Exception:
                            pass
                    self._installation_mode = False
                    self.js.call("setInstallationMode", False)
                except Exception as e:
                    self.js.call("logMessage", f"Installation error: {e}", "error")
                    self._installation_mode = False
                    self.js.call("setInstallationMode", False)

            threading.Thread(target=install_thread, daemon=True).start()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    # ── Advanced config / script generation ──────────────────────────────

    def get_installation_options(self):
        return {
            "success": True,
            "options": {
                "epd_versions": [
                    {"value": "epd2in13", "label": "epd2in13 (Original)"},
                    {"value": "epd2in13_V2", "label": "epd2in13_V2"},
                    {"value": "epd2in13_V3", "label": "epd2in13_V3"},
                    {"value": "epd2in13_V4", "label": "epd2in13_V4 (Recommended)"},
                    {"value": "epd2in7", "label": "epd2in7 (2.7 inch)"},
                ],
                "apt_packages": [
                    {"name": "python3-pip", "required": True, "description": "Python package manager"},
                    {"name": "wget", "required": True, "description": "Network downloader"},
                    {"name": "git", "required": True, "description": "Version control"},
                    {"name": "bluez", "required": True, "description": "Bluetooth stack"},
                    {"name": "bluez-tools", "required": True, "description": "Bluetooth tools"},
                    {"name": "python3-pil", "required": True, "description": "Python imaging library"},
                    {"name": "python3-dev", "required": True, "description": "Python development files"},
                    {"name": "python3-psutil", "required": True, "description": "System monitoring"},
                    {"name": "libgpiod-dev", "required": True, "description": "GPIO dev"},
                    {"name": "libi2c-dev", "required": True, "description": "I2C dev"},
                    {"name": "build-essential", "required": True, "description": "Build tools"},
                    {"name": "libopenjp2-7", "required": False, "description": "JPEG 2000 codec"},
                    {"name": "nmap", "required": False, "description": "Network exploration"},
                    {"name": "dhcpcd5", "required": False, "description": "DHCP client"},
                    {"name": "dnsmasq", "required": False, "description": "DNS/DHCP server"},
                    {"name": "gobuster", "required": False, "description": "Dir scanner"},
                    {"name": "arping", "required": False, "description": "ARP ping"},
                    {"name": "arp-scan", "required": False, "description": "ARP scanner"},
                    {"name": "libopenblas-dev", "required": False, "description": "BLAS"},
                    {"name": "python3-dbus", "required": False, "description": "D-Bus"},
                    {"name": "bridge-utils", "required": False, "description": "Bridge utils"},
                    {"name": "libjpeg-dev", "required": False, "description": "JPEG dev"},
                    {"name": "zlib1g-dev", "required": False, "description": "zlib dev"},
                    {"name": "libpng-dev", "required": False, "description": "PNG dev"},
                    {"name": "libffi-dev", "required": False, "description": "FFI"},
                    {"name": "libssl-dev", "required": False, "description": "SSL dev"},
                    {"name": "libssl1.1", "required": False, "description": "SSL runtime"},
                    {"name": "libatlas-base-dev", "required": False, "description": "ATLAS"},
                ],
                "pip_packages": [
                    {"name": "RPi.GPIO", "version": "0.7.1", "required": True},
                    {"name": "spidev", "version": "3.6", "required": True},
                    {"name": "pillow", "version": "10.4.0", "required": True},
                    {"name": "requests", "version": "2.32.3", "required": True},
                    {"name": "flask", "version": "3.0.3", "required": True},
                    {"name": "netifaces", "version": "0.11.0", "required": True},
                    {"name": "psutil", "version": "6.0.0", "required": True},
                    {"name": "paramiko", "version": "3.4.0", "required": True},
                    {"name": "scapy", "version": "2.5.0", "required": False},
                    {"name": "telnetlib3", "version": "2.0.4", "required": False},
                    {"name": "numpy", "version": "1.26.4", "required": False},
                    {"name": "cryptography", "version": "42.0.5", "required": False},
                    {"name": "pycryptodome", "version": "3.20.0", "required": False},
                ],
                "system_configs": [
                    {"key": "enable_spi", "label": "Enable SPI Interface", "default": True},
                    {"key": "enable_i2c", "label": "Enable I2C Interface", "default": True},
                    {"key": "enable_bluetooth", "label": "Enable Bluetooth Service", "default": True},
                    {"key": "enable_usb_gadget", "label": "Enable USB Gadget Mode", "default": True},
                    {"key": "configure_wifi", "label": "Configure WiFi from preconfigured file", "default": True},
                    {"key": "set_limits", "label": "Configure system limits (file descriptors)", "default": True},
                    {"key": "install_scripts", "label": "Install Bjorn helper scripts", "default": True},
                    {"key": "create_backup", "label": "Create initial backup archive", "default": True},
                    {"key": "setup_service", "label": "Setup systemd service", "default": True},
                    {"key": "configure_networking", "label": "Configure network interfaces", "default": True},
                ],
            },
        }

    def generate_custom_installer(self, config):
        try:
            self.js.call("logMessage", "Generating custom installer script...", "info")
            temp_path = ScriptGenerator.generate(config)
            self._custom_script_path = temp_path

            apt_count = len(config.get("apt_packages", []))
            pip_count = len(config.get("pip_packages", []))
            snip_count = len(config.get("user_snippets", []) or [])

            self.js.call("logMessage", "Custom installer script generated successfully", "success")
            self.js.call(
                "updateAdvancedConfigStatus",
                f"Advanced configuration script ready ({apt_count} APT, {pip_count} PIP; {snip_count} snippets)",
            )
            return {"success": True, "script_path": temp_path}
        except Exception as e:
            self.js.call("logMessage", f"Failed to generate custom installer: {e}", "error")
            return {"success": False, "error": str(e)}

    # ── Remote actions ───────────────────────────────────────────────────

    def restart_bjorn(self):
        try:
            if not self.ssh_worker or not self.ssh_worker._connected:
                return {"success": False, "error": "Not connected to SSH"}

            def restart_thread():
                try:
                    self.ssh_worker.restart_bjorn_service()
                except Exception as e:
                    self.js.call("logMessage", f"Restart error: {e}", "error")

            threading.Thread(target=restart_thread, daemon=True).start()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def change_epd_type(self, epd_version):
        try:
            if not self.ssh_worker or not self.ssh_worker._connected:
                return {"success": False, "error": "Not connected to SSH"}

            def change_thread():
                try:
                    self.ssh_worker.change_epd_type(epd_version)
                except Exception as e:
                    self.js.call("logMessage", f"EPD change error: {e}", "error")

            threading.Thread(target=change_thread, daemon=True).start()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def stream_logs(self):
        try:
            if not self.ssh_worker or not self.ssh_worker._connected:
                return {"success": False, "error": "Not connected to SSH"}
            if self._log_stream_thread and self._log_stream_thread.is_alive():
                return {"success": False, "error": "Log streaming already active"}

            self._log_stream_stop.clear()

            def stream_thread():
                try:
                    self.ssh_worker.stream_logs(self._log_stream_stop)
                except Exception as e:
                    self.js.call("logMessage", f"Log streaming error: {e}", "error")

            self._log_stream_thread = threading.Thread(target=stream_thread, daemon=True)
            self._log_stream_thread.start()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def stop_log_stream(self):
        self._log_stream_stop.set()
        self.js.call("logMessage", "Log streaming stopped", "warning")
        return {"success": True}

    def reboot_target(self):
        try:
            if not self.ssh_worker or not self.ssh_worker._connected:
                return {"success": False, "error": "Not connected to SSH"}

            def reboot_thread():
                try:
                    self.ssh_worker.reboot()
                    time.sleep(2)
                    self.disconnect_ssh()
                except Exception as e:
                    self.js.call("logMessage", f"Reboot error: {e}", "error")

            threading.Thread(target=reboot_thread, daemon=True).start()
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def get_system_info(self):
        return {
            "version": "11.0.0",
            "python_version": sys.version,
            "platform": sys.platform,
            "connected": self._connected,
            "connected_ip": self._connected_ip,
            "installation_mode": self._installation_mode,
        }

    def get_script_info(self):
        info = {"default_script_exists": False, "custom_script_uploaded": False, "script_paths": {}}
        try:
            default_path = self._get_install_script()
            info["default_script_exists"] = os.path.exists(default_path)
            info["script_paths"]["default"] = default_path
        except Exception:
            pass
        if self._custom_script_path and os.path.exists(self._custom_script_path):
            info["custom_script_uploaded"] = True
            info["script_paths"]["custom"] = self._custom_script_path
        return info

    def preview_script(self, script_type="default"):
        try:
            if script_type == "custom" and self._custom_script_path:
                script_path = self._custom_script_path
            else:
                script_path = self._get_install_script()
            if not os.path.exists(script_path):
                return {"success": False, "error": "Script file not found"}
            with open(script_path, "r", encoding="utf-8") as f:
                lines = f.readlines()
            preview_lines = lines[:20]
            return {
                "success": True,
                "preview": "".join(preview_lines),
                "total_lines": len(lines),
                "showing_lines": len(preview_lines),
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    # ── Helpers ──────────────────────────────────────────────────────────

    def _save_temp_file(self, file_data: str, filename: str) -> str:
        file_content = base64.b64decode(file_data.split(",")[1])
        temp_dir = tempfile.gettempdir()
        temp_path = os.path.join(temp_dir, filename)
        with open(temp_path, "wb") as f:
            f.write(file_content)
        return temp_path

    def _get_assets_dir(self) -> str:
        """Return the path to the assets/ directory containing install scripts."""
        base = pathlib.Path(__file__).resolve().parent.parent
        assets_dir = base / "assets"
        if (assets_dir / "install_bjorn.sh").exists():
            return str(assets_dir)
        # Fallback: create a minimal script in-place
        try:
            assets_dir.mkdir(parents=True, exist_ok=True)
            (assets_dir / "install_bjorn.sh").write_text(
                INSTALL_SH_FALLBACK, encoding="utf-8"
            )
        except Exception:
            pass
        return str(assets_dir)

    def _get_install_script(self) -> str:
        """Legacy: return path to install_bjorn.sh."""
        return os.path.join(self._get_assets_dir(), "install_bjorn.sh")

    def _read_prefs(self) -> dict:
        with self._prefs_lock:
            self._migrate_legacy_prefs_if_needed()
            try:
                if self._prefs_path.exists():
                    return json.loads(self._prefs_path.read_text(encoding="utf-8"))
            except Exception:
                pass
            return {}

    def _write_prefs(self, prefs: dict) -> None:
        with self._prefs_lock:
            self._prefs_path.parent.mkdir(parents=True, exist_ok=True)
            self._prefs_path.write_text(
                json.dumps(prefs, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )

    def _resolve_prefs_path(self) -> pathlib.Path:
        if sys.platform == "win32":
            appdata = os.environ.get("APPDATA")
            base = pathlib.Path(appdata) if appdata else (pathlib.Path.home() / "AppData" / "Roaming")
            return base / "BJORNManager" / "preferences.json"
        xdg = os.environ.get("XDG_CONFIG_HOME")
        base = pathlib.Path(xdg) if xdg else (pathlib.Path.home() / ".config")
        return base / "bjorn_manager" / "preferences.json"

    def _migrate_legacy_prefs_if_needed(self) -> None:
        if self._prefs_path.exists():
            return
        try:
            if self._legacy_prefs_path.exists():
                self._prefs_path.parent.mkdir(parents=True, exist_ok=True)
                self._prefs_path.write_text(
                    self._legacy_prefs_path.read_text(encoding="utf-8"),
                    encoding="utf-8",
                )
        except Exception:
            pass

    def _read_registry_language(self) -> str | None:
        if sys.platform != "win32":
            return None
        try:
            import winreg  # type: ignore

            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self._registry_base, 0, winreg.KEY_READ) as key:
                value, _ = winreg.QueryValueEx(key, "Language")
            if isinstance(value, str) and value.strip():
                return value.strip().lower()
        except Exception:
            pass
        return None

    def _write_registry_language(self, lang: str) -> bool:
        if sys.platform != "win32":
            return False
        try:
            import winreg  # type: ignore

            with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self._registry_base) as key:
                winreg.SetValueEx(key, "Language", 0, winreg.REG_SZ, lang)
            return True
        except Exception:
            return False


# ── HTML loader ──────────────────────────────────────────────────────────────

def get_base_path() -> pathlib.Path:
    if getattr(sys, "frozen", False):
        return pathlib.Path(sys._MEIPASS)
    return pathlib.Path(__file__).resolve().parent.parent


def get_window_source():
    p = get_base_path() / EXTERNAL_HTML_FILENAME
    if p.exists():
        return {"url": p.as_uri()}
    return {
        "html": "<!DOCTYPE html><html><body><h1>BJORN UI</h1>"
        "<p>Missing: bjorn_ui.html</p></body></html>"
    }


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    os.environ["PYTHONUTF8"] = "1"
    api = BJORNWebAPI()

    src = get_window_source()
    window_kwargs = dict(
        title=APP_TITLE,
        width=1400,
        height=1200,
        min_size=(1000, 700),
        js_api=api,
        resizable=True,
        on_top=False,
        frameless=True,
    )

    if "url" in src:
        window = webview.create_window(url=src["url"], **window_kwargs)
    else:
        window = webview.create_window(html=src["html"], **window_kwargs)

    api.set_window(window)

    # FIX: Use event-based readiness instead of time.sleep(10)
    window.events.loaded += api.on_loaded

    try:
        webview.start(debug=False, http_server=True)
    except Exception as e:
        print(f"[ERROR] webview.start failed: {e}")

    # Cleanup on exit
    api.js.stop()
    if api.discovery:
        api.discovery.stop()
    if api.ssh_worker:
        api.ssh_worker.close()
