from __future__ import annotations

import os
import re
import shlex
import threading
import time
from pathlib import Path
from typing import Callable, Optional

import paramiko

from bjorn_manager.ssh.config import SSHConfig

STEP_PATTERN = re.compile(r"Step\s+(\d+)\s+of\s+(\d+)", re.I)

_PRIVATE_KEY_NAMES = ["id_ed25519", "id_rsa", "id_ecdsa"]

_DEPLOY_SCRIPT = r"""#!/bin/bash
set -e
cd /home/bjorn
rm -rf Bjorn.tmp
mkdir -p Bjorn.tmp

if command -v unzip >/dev/null 2>&1; then
    unzip -o Bjorn.zip -d Bjorn.tmp
else
    python3 - <<'PY'
import zipfile
z = zipfile.ZipFile('Bjorn.zip')
z.extractall('Bjorn.tmp')
PY
fi

TOP=$(ls Bjorn.tmp | head -n1)
if [ -d "Bjorn.tmp/$TOP/Bjorn" ]; then
    sudo mv "Bjorn.tmp/$TOP/Bjorn" Bjorn.new
elif [ -d "Bjorn.tmp/Bjorn" ]; then
    sudo mv "Bjorn.tmp/Bjorn" Bjorn.new
else
    sudo mv Bjorn.tmp Bjorn.new
fi

sudo rm -rf Bjorn.bak && mv -f Bjorn Bjorn.bak 2>/dev/null || true
sudo mv -f Bjorn.new Bjorn
chown -R bjorn:bjorn /home/bjorn/Bjorn || true
chmod -R 755 /home/bjorn/Bjorn || true
rm -f Bjorn.zip
echo "Deploy complete"
"""


class SSHWorker:
    def __init__(self, config: SSHConfig, callback: Callable[..., None]) -> None:
        self._config = config
        self._callback = callback
        self._client: Optional[paramiko.SSHClient] = None
        self._connected = False

    def _resolve_key_path(self) -> Optional[str]:
        if self._config.key_path:
            expanded = os.path.expanduser(os.path.expandvars(self._config.key_path))
            if os.path.isfile(expanded):
                return expanded
            return None
        ssh_dir = Path.home() / ".ssh"
        for name in _PRIVATE_KEY_NAMES:
            candidate = ssh_dir / name
            if candidate.is_file():
                return str(candidate)
        return None

    def log(self, message: str, level: str = "info") -> None:
        self._callback("log", message, level)

    def update_progress(self, current: int, total: int, text: str) -> None:
        self._callback("progress", current, total, text)

    def connect(self) -> bool:
        try:
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

            key_path = self._resolve_key_path()
            connect_kwargs: dict = {
                "hostname": self._config.host,
                "port": self._config.port,
                "username": self._config.user,
                "timeout": 15,
                "allow_agent": False,
                "look_for_keys": False,
            }

            connected = False
            if key_path:
                try:
                    connect_kwargs["key_filename"] = key_path
                    if self._config.password:
                        connect_kwargs["passphrase"] = self._config.password
                    client.connect(**connect_kwargs)
                    connected = True
                    self.log(f"[SSH] Connected via key: {os.path.basename(key_path)}")
                except (
                    paramiko.AuthenticationException,
                    paramiko.SSHException,
                    FileNotFoundError,
                ):
                    self.log("[SSH] Key auth failed, falling back to password", "warning")
                    connect_kwargs.pop("key_filename", None)
                    connect_kwargs.pop("passphrase", None)

            if not connected:
                if not self._config.password:
                    self.log("[SSH] No password available for fallback auth", "error")
                    return False
                connect_kwargs["password"] = self._config.password
                client.connect(**connect_kwargs)
                self.log("[SSH] Connected via password")

            transport = client.get_transport()
            if transport:
                transport.set_keepalive(30)

            self._client = client
            self._connected = True
            return True
        except Exception as exc:
            self.log(f"[SSH] Connection failed: {exc}", "error")
            self._connected = False
            return False

    def close(self) -> None:
        self._connected = False
        if self._client:
            try:
                self._client.close()
            except Exception:
                pass
            finally:
                self._client = None
        self.log("[SSH] Disconnected.", "warning")

    def _ensure_connected(self) -> paramiko.SSHClient:
        if self._client is None:
            raise RuntimeError("SSH client is not connected")
        return self._client

    def exec_simple(
        self,
        command: str,
        input_data: Optional[str] = None,
        timeout: int = 30,
    ) -> tuple[int, str, str]:
        client = self._ensure_connected()
        stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
        if input_data is not None:
            stdin.write(input_data)
            stdin.flush()
            stdin.channel.shutdown_write()
        exit_code = stdout.channel.recv_exit_status()
        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        return exit_code, out, err

    def _sudo_exec(
        self,
        command: str,
        timeout: int = 30,
    ) -> tuple[int, str, str]:
        password = self._config.sudo_password or self._config.password or ""
        sudo_cmd = f"sudo -S {command}"
        return self.exec_simple(sudo_cmd, input_data=password + "\n", timeout=timeout)

    def upload_file(self, local_path: str, remote_path: str) -> None:
        client = self._ensure_connected()
        sftp = client.open_sftp()
        try:
            self.log(f"[SFTP] Upload {os.path.basename(local_path)} → {remote_path}")
            sftp.put(local_path, remote_path)
            self.log("[SFTP] Upload complete.", "success")
        finally:
            sftp.close()

    def deploy_bjorn_zip(self, local_zip_path: str) -> bool:
        """Deploy Bjorn.zip for debug mode to /home/bjorn/Bjorn."""
        try:
            remote_zip = "/home/bjorn/Bjorn.zip"
            self.upload_file(local_zip_path, remote_zip)
            self.log("[RUN] Extracting Bjorn.zip to /home/bjorn/Bjorn ...", "info")

            # Upload and run deploy script
            client = self._ensure_connected()
            sftp = client.open_sftp()
            remote_script = "/home/bjorn/deploy_tmp.sh"
            try:
                with sftp.file(remote_script, "w") as f:
                    f.write(_DEPLOY_SCRIPT)
            finally:
                sftp.close()

            self.exec_simple(f"chmod +x {shlex.quote(remote_script)}", timeout=10)
            password = self._config.sudo_password or self._config.password or ""
            exit_code, out, err = self.exec_simple(
                f"sudo -S bash {shlex.quote(remote_script)}",
                input_data=password + "\n",
                timeout=120,
            )
            # Cleanup script
            self.exec_simple(f"rm -f {shlex.quote(remote_script)}", timeout=10)

            if out.strip():
                self.log(out.strip())
            if exit_code != 0:
                self.log(f"[DEPLOY] Failed (exit {exit_code}): {err}", "error")
                return False

            self.log("[DEPLOY] Bjorn.zip deployed successfully", "success")
            return True
        except Exception as exc:
            self.log(f"[DEPLOY] Failed: {exc}", "error")
            return False

    def upload_install_scripts(self, assets_dir: str) -> str:
        """Upload install_bjorn.sh + lib/ folder to /home/bjorn/.

        Returns the remote path of the orchestrator script.
        """
        client = self._ensure_connected()
        sftp = client.open_sftp()
        try:
            local_script = os.path.join(assets_dir, "install_bjorn.sh")
            remote_script = "/home/bjorn/install_bjorn.sh"
            self.log("[SFTP] Uploading install_bjorn.sh")
            sftp.put(local_script, remote_script)

            # Create remote lib/ directory
            remote_lib = "/home/bjorn/lib"
            try:
                sftp.mkdir(remote_lib)
            except IOError:
                pass  # already exists

            local_lib = os.path.join(assets_dir, "lib")
            for fname in sorted(os.listdir(local_lib)):
                if fname.endswith(".sh"):
                    local_path = os.path.join(local_lib, fname)
                    remote_path = f"{remote_lib}/{fname}"
                    self.log(f"[SFTP] Uploading lib/{fname}")
                    sftp.put(local_path, remote_path)

            self.log("[SFTP] All install scripts uploaded", "success")
            return remote_script
        finally:
            sftp.close()

    def run_install(
        self,
        script_path_remote: str,
        params: dict,
        reboot_after: bool = False,
    ) -> bool:
        """Run the installation script in non-interactive mode using env vars."""
        try:
            client = self._ensure_connected()
            password = self._config.sudo_password or self._config.password or ""

            # Map EPD choice number to version string
            epd_map = {
                1: "epd2in13", 2: "epd2in13_V2", 3: "epd2in13_V3",
                4: "epd2in13_V4", 5: "epd2in7",
            }
            epd_choice = params.get("epd_choice", 4)
            epd_version = epd_map.get(int(epd_choice), "epd2in13_V4")

            manual_mode = "True" if params.get("manual_mode", True) else "False"
            enable_auth = "y" if params.get("webui_enable_auth", False) else "n"
            web_pass = params.get("webui_password", "")
            bt_mac = params.get("bt_mac", "60:57:C8:47:E3:88")
            git_branch = params.get("git_branch", "main")
            install_mode = params.get("install_mode", "online")
            install_mode_flag = {
                "online": "-online", "local": "-local", "debug": "-debug",
            }.get(install_mode, "-online")

            # Build env vars for non-interactive mode
            env_parts = [
                "NON_INTERACTIVE=1",
                f"EPD_VERSION={shlex.quote(epd_version)}",
                f"MANUAL_MODE={shlex.quote(manual_mode)}",
                f"enable_auth={shlex.quote(enable_auth)}",
                f"WEBUI_PASSWORD={shlex.quote(web_pass)}",
                f"WEBUI_PASSWORD_CONFIRM={shlex.quote(web_pass)}",
                f"BLUETOOTH_MAC_ADDRESS={shlex.quote(bt_mac)}",
                f"GIT_BRANCH={shlex.quote(git_branch)}",
            ]
            env_str = " ".join(env_parts)

            # chmod the script
            self.exec_simple(f"chmod +x {shlex.quote(script_path_remote)}", timeout=10)

            safe_script = shlex.quote(script_path_remote)
            safe_flag = shlex.quote(install_mode_flag)
            command = f"sudo -S {env_str} bash {safe_script} {safe_flag}"

            self.log(f"[RUN] Starting installation (branch={git_branch}, mode={install_mode})")

            chan = client.get_transport().open_session()
            chan.get_pty()
            chan.exec_command(command)

            # Send sudo password when prompted
            pw_sent = False
            buff = b""

            while True:
                if chan.recv_ready():
                    data = chan.recv(4096)
                    buff += data
                    text = data.decode("utf-8", errors="ignore")
                    for line in text.splitlines():
                        if line.strip():
                            self.log(line, "info")
                            m = STEP_PATTERN.search(line)
                            if m:
                                self.update_progress(
                                    int(m.group(1)), int(m.group(2)),
                                    f"Step {m.group(1)}/{m.group(2)}"
                                )

                if not pw_sent:
                    lower_buff = buff.lower()
                    if b"[sudo]" in lower_buff or b"password for" in lower_buff:
                        chan.send(password + "\n")
                        pw_sent = True
                        buff = b""
                        self.log("[SUDO] Password sent", "info")

                if chan.exit_status_ready():
                    # Drain remaining output
                    while chan.recv_ready():
                        data = chan.recv(4096)
                        text = data.decode("utf-8", errors="ignore")
                        for line in text.splitlines():
                            if line.strip():
                                self.log(line, "info")
                    rc = chan.recv_exit_status()
                    if rc == 0:
                        self.log("Installation completed successfully!", "success")
                    else:
                        self.log(f"Installation failed with exit code {rc}", "error")

                    if reboot_after and rc == 0:
                        self.reboot()
                    return rc == 0

                time.sleep(0.1)
        except Exception as exc:
            self.log(f"Error during installation: {exc}", "error")
            return False

    def restart_bjorn_service(self) -> bool:
        try:
            self.log("[SERVICE] Restarting BJORN service...")
            exit_code, out, err = self._sudo_exec(
                "systemctl restart bjorn.service", timeout=60
            )
            if exit_code != 0:
                self.log(f"[SERVICE] Restart failed: {err}", "error")
                return False
            self.log("[SERVICE] BJORN service restarted", "success")
            return True
        except Exception as exc:
            self.log(f"[SERVICE] Restart failed: {exc}", "error")
            return False

    def change_epd_type(self, epd_version: str) -> bool:
        try:
            safe_version = shlex.quote(epd_version)
            cmd = f"cd /home/bjorn/Bjorn && sed -i 's/\"epd_type\": \"epd2in13_[^\"]*\"/\"epd_type\": {safe_version}/g' shared.py"
            self.log(f"[CONFIG] Changing EPD type to {epd_version}")
            exit_code, out, err = self.exec_simple(cmd, timeout=15)
            if exit_code != 0:
                self.log(f"[CONFIG] EPD change failed: {err}", "error")
                return False
            # Clear config cache
            self._sudo_exec("rm -rf /home/bjorn/Bjorn/config/*.json", timeout=15)
            self.log("[CONFIG] Cleared configuration files", "info")
            return self.restart_bjorn_service()
        except Exception as exc:
            self.log(f"[CONFIG] EPD change failed: {exc}", "error")
            return False

    def stream_logs(self, stop_event: threading.Event) -> None:
        try:
            client = self._ensure_connected()
            self.log("[LOGS] Starting log stream...", "info")
            stdin, stdout, stderr = client.exec_command(
                "journalctl -fu bjorn.service", timeout=None
            )
            channel = stdout.channel

            while not stop_event.is_set():
                if channel.recv_ready():
                    data = channel.recv(4096).decode("utf-8", errors="replace")
                    for line in data.splitlines():
                        if stop_event.is_set():
                            break
                        if line.strip():
                            self.log(f"[BJORN] {line}", "info")
                elif channel.exit_status_ready():
                    break
                else:
                    time.sleep(0.1)

            channel.close()
        except Exception as exc:
            if not stop_event.is_set():
                self.log(f"Log streaming error: {exc}", "error")

    def reboot(self) -> None:
        try:
            self.log("[REBOOT] System reboot initiated", "warning")
            password = self._config.sudo_password or self._config.password or ""
            client = self._ensure_connected()
            stdin, stdout, stderr = client.exec_command("sudo -S reboot", timeout=10)
            stdin.write(password + "\n")
            stdin.flush()
            try:
                stdout.channel.recv_exit_status()
            except Exception:
                pass
        except Exception as exc:
            self.log(f"Reboot command: {exc}", "warning")
