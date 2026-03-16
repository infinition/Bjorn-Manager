from __future__ import annotations

import io
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


def _upload_text_lf(sftp: paramiko.SFTPClient, local_path: str, remote_path: str) -> None:
    """Upload a text file, converting CRLF → LF on the fly.

    This prevents '\\r' syntax errors when shell scripts edited on Windows
    are uploaded to a Linux target via SFTP.
    """
    with open(local_path, "r", encoding="utf-8") as f:
        content = f.read()
    content = content.replace("\r\n", "\n").replace("\r", "\n")
    sftp.putfo(io.BytesIO(content.encode("utf-8")), remote_path)


def _upload_remote_text(
    sftp: paramiko.SFTPClient,
    remote_path: str,
    content: str,
) -> None:
    payload = content.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
    sftp.putfo(io.BytesIO(payload), remote_path)


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
            # Convert CRLF → LF for shell scripts and text config files
            if local_path.endswith((".sh", ".py", ".conf", ".cfg", ".txt", ".json", ".service")):
                _upload_text_lf(sftp, local_path, remote_path)
            else:
                sftp.put(local_path, remote_path)
            self.log("[SFTP] Upload complete.", "success")
        finally:
            sftp.close()

    def deploy_bjorn_zip(self, local_zip_path: str) -> bool:
        """Deploy Bjorn.zip for debug mode to /home/bjorn/Bjorn."""
        try:
            remote_zip = "/home/bjorn/Bjorn.zip"
            # Zip is binary — use raw sftp.put via direct SFTP (bypass upload_file text conversion)
            client = self._ensure_connected()
            sftp = client.open_sftp()
            try:
                self.log(f"[SFTP] Upload {os.path.basename(local_zip_path)} → {remote_zip}")
                sftp.put(local_zip_path, remote_zip)
                self.log("[SFTP] Upload complete.", "success")
            finally:
                sftp.close()

            self.log("[RUN] Extracting Bjorn.zip to /home/bjorn/Bjorn ...", "info")

            # Upload and run deploy script (convert CRLF just in case)
            client = self._ensure_connected()
            sftp = client.open_sftp()
            remote_script = "/home/bjorn/deploy_tmp.sh"
            try:
                content = _DEPLOY_SCRIPT.replace("\r\n", "\n").replace("\r", "\n")
                sftp.putfo(io.BytesIO(content.encode("utf-8")), remote_script)
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

        All .sh files are uploaded with CRLF → LF conversion to prevent
        '\\r' syntax errors on the Linux target.

        Returns the remote path of the orchestrator script.
        """
        client = self._ensure_connected()
        sftp = client.open_sftp()
        try:
            local_script = os.path.join(assets_dir, "install_bjorn.sh")
            remote_script = "/home/bjorn/install_bjorn.sh"
            self.log("[SFTP] Uploading install_bjorn.sh")
            _upload_text_lf(sftp, local_script, remote_script)

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
                    _upload_text_lf(sftp, local_path, remote_path)

            self.log("[SFTP] All install scripts uploaded", "success")
            return remote_script
        finally:
            sftp.close()

    def start_install(
        self,
        script_path_remote: str,
        params: dict,
    ) -> dict:
        """Start the installation script in the background and return session info."""
        try:
            password = self._config.sudo_password or self._config.password or ""

            # Map EPD choice number to version string
            epd_map = {
                1: "epd2in13", 2: "epd2in13_V2", 3: "epd2in13_V3",
                4: "epd2in13_V4", 5: "epd2in7",
            }
            epd_choice = params.get("epd_choice", 4)
            epd_version = epd_map.get(int(epd_choice), "epd2in13_V4")

            operation_mode = str(params.get("operation_mode", "") or "").strip().lower()
            if operation_mode not in {"auto", "manual", "ai"}:
                operation_mode = "manual" if params.get("manual_mode", True) else "ai"
            manual_mode = "True" if operation_mode == "manual" else "False"
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
                f"OPERATION_MODE={shlex.quote(operation_mode)}",
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
            session_id = f"bjorn_install_{int(time.time())}"
            remote_runner = f"/home/{self._config.user}/.{session_id}.sh"
            remote_stream_log = f"/tmp/{session_id}.stream.log"
            remote_status_file = f"/tmp/{session_id}.status"

            runner_content = f"""#!/bin/bash
set +e
rm -f {shlex.quote(remote_stream_log)} {shlex.quote(remote_status_file)}
env {env_str} bash {safe_script} {safe_flag} > {shlex.quote(remote_stream_log)} 2>&1
rc=$?
printf '%s\\n' "$rc" > {shlex.quote(remote_status_file)}
exit 0
"""

            client = self._ensure_connected()
            sftp = client.open_sftp()
            try:
                _upload_remote_text(sftp, remote_runner, runner_content)
            finally:
                sftp.close()

            self.exec_simple(f"chmod +x {shlex.quote(remote_runner)}", timeout=10)

            self.log(f"[RUN] Starting installation (branch={git_branch}, mode={install_mode}, operation={operation_mode})")
            self.log(f"[RUN] Remote stream log: {remote_stream_log}", "info")

            start_command = (
                "sudo -S -p '' sh -lc "
                + shlex.quote(
                    f"nohup bash {shlex.quote(remote_runner)} >/dev/null 2>&1 & echo $!"
                )
            )
            exit_code, out, err = self.exec_simple(
                start_command,
                input_data=password + "\n",
                timeout=30,
            )
            if exit_code != 0:
                self.log(f"[RUN] Failed to start remote installer: {err or out}", "error")
                return False

            if password:
                self.log("[SUDO] Password sent", "info")

            remote_pid = out.strip() or "unknown"
            self.log(f"[RUN] Remote installer started (pid={remote_pid})", "info")
            return {
                "id": session_id,
                "remote_pid": remote_pid,
                "remote_runner": remote_runner,
                "remote_stream_log": remote_stream_log,
                "remote_status_file": remote_status_file,
                "next_line": 1,
                "finished": False,
                "result": None,
            }
        except Exception as exc:
            self.log(f"Error during installation startup: {exc}", "error")
            raise

    def monitor_install(
        self,
        session: dict,
        reboot_after: bool = False,
    ) -> Optional[bool]:
        """Monitor an already-started remote installation session.

        Returns:
            True if the installer completed successfully,
            False if it completed with a non-zero exit code,
            None if monitoring was interrupted before the final result was known.
        """
        reconnect_attempts = 0
        next_line = int(session.get("next_line", 1) or 1)
        remote_runner = str(session["remote_runner"])
        remote_stream_log = str(session["remote_stream_log"])
        remote_status_file = str(session["remote_status_file"])

        while True:
            try:
                reconnect_attempts = 0

                log_command = (
                    f"sed -n '{next_line},$p' {shlex.quote(remote_stream_log)} 2>/dev/null || true"
                )
                _, log_out, _ = self.exec_simple(log_command, timeout=20)
                all_lines = log_out.splitlines()
                for line in all_lines:
                    if not line.strip():
                        continue
                    self.log(line, "info")
                    m = STEP_PATTERN.search(line)
                    if m:
                        self.update_progress(
                            int(m.group(1)), int(m.group(2)),
                            f"Step {m.group(1)}/{m.group(2)}"
                        )
                next_line += len(all_lines)
                session["next_line"] = next_line

                _, status_out, _ = self.exec_simple(
                    f"cat {shlex.quote(remote_status_file)} 2>/dev/null || true",
                    timeout=20,
                )
                status_text = status_out.strip()
                if status_text:
                    try:
                        rc = int(status_text.splitlines()[-1].strip())
                    except ValueError:
                        rc = 1

                    session["finished"] = True
                    session["result"] = rc == 0

                    if rc == 0:
                        self.log("Installation completed successfully!", "success")
                    else:
                        self.log(f"Installation failed with exit code {rc}", "error")

                    self.exec_simple(
                        "rm -f "
                        + " ".join(
                            shlex.quote(path)
                            for path in [remote_runner, remote_stream_log, remote_status_file]
                        ),
                        timeout=15,
                    )

                    if reboot_after and rc == 0:
                        self.reboot()
                    return rc == 0

                time.sleep(1.0)
            except Exception as exc:
                reconnect_attempts += 1
                self.log(
                    f"[RUN] Lost SSH connection while monitoring install ({exc}); reconnect attempt {reconnect_attempts}/5",
                    "warning",
                )
                self.close()
                if reconnect_attempts > 5 or not self.connect():
                    self.log("[RUN] Unable to reconnect to monitor the remote installer", "error")
                    session["finished"] = False
                    session["result"] = None
                    session["next_line"] = next_line
                    return None
                time.sleep(2.0)

    def run_install(
        self,
        script_path_remote: str,
        params: dict,
        reboot_after: bool = False,
    ) -> Optional[bool]:
        session = self.start_install(script_path_remote, params)
        return self.monitor_install(session, reboot_after=reboot_after)

    def stop_install(self, session: dict) -> bool:
        """Stop a running remote installation session if possible."""
        try:
            password = self._config.sudo_password or self._config.password or ""
            remote_pid = str(session.get("remote_pid", "") or "").strip()
            remote_runner = str(session.get("remote_runner", "") or "").strip()
            remote_stream_log = str(session.get("remote_stream_log", "") or "").strip()
            remote_status_file = str(session.get("remote_status_file", "") or "").strip()

            if not remote_pid or remote_pid == "unknown":
                self.log("[RUN] No remote PID is available for this install session", "warning")
                return False

            stop_script = (
                "sh -lc "
                + shlex.quote(
                    " ; ".join(
                        [
                            f"pkill -TERM -P {shlex.quote(remote_pid)} 2>/dev/null || true",
                            f"kill -TERM {shlex.quote(remote_pid)} 2>/dev/null || true",
                            "sleep 2",
                            f"pkill -KILL -P {shlex.quote(remote_pid)} 2>/dev/null || true",
                            f"kill -KILL {shlex.quote(remote_pid)} 2>/dev/null || true",
                            f"printf '%s\\n' 130 > {shlex.quote(remote_status_file)}",
                            "exit 0",
                        ]
                    )
                )
            )
            exit_code, out, err = self.exec_simple(
                f"sudo -S -p '' {stop_script}",
                input_data=password + "\n",
                timeout=30,
            )
            if exit_code != 0:
                self.log(f"[RUN] Failed to stop remote installer: {err or out}", "error")
                return False

            cleanup_targets = [p for p in [remote_runner, remote_stream_log] if p]
            if cleanup_targets:
                self.exec_simple(
                    "rm -f " + " ".join(shlex.quote(path) for path in cleanup_targets),
                    timeout=15,
                )

            self.log("[RUN] Remote installation stop requested", "warning")
            return True
        except Exception as exc:
            self.log(f"[RUN] Failed to stop remote installer: {exc}", "error")
            return False

    def delete_remote_path(self, remote_path: str, recursive: bool = False) -> bool:
        try:
            safe_path = shlex.quote(remote_path)
            rm_flag = "-rf" if recursive else "-f"
            self.log(f"[REMOTE] Deleting {remote_path}...", "warning")
            exit_code, out, err = self._sudo_exec(f"rm {rm_flag} {safe_path}", timeout=30)
            if exit_code != 0:
                self.log(f"[REMOTE] Delete failed for {remote_path}: {err or out}", "error")
                return False
            self.log(f"[REMOTE] Deleted {remote_path}", "success")
            return True
        except Exception as exc:
            self.log(f"[REMOTE] Delete failed for {remote_path}: {exc}", "error")
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
