# README_DEV

Developer-oriented notes for BJORN Manager.

## Scope

This file is for contributors and maintainers.
For end users, see `README.md`.

## Architecture

- Frontend: `bjorn_ui.html`
- Backend API/orchestrator: `bjorn_manager/app.py` (`BJORNWebAPI`)
- Python -> JS bridge queue: `bjorn_manager/ui/js_bridge.py`
- Discovery engine: `bjorn_manager/discovery/manager.py`
- SSH worker: `bjorn_manager/ssh/worker.py`
- Installer generation/validation:
  - `bjorn_manager/installer/script_generator.py`
  - `bjorn_manager/installer/validator.py`

## Run From Source

```bash
pip install -r requirements.txt
python run.py
```

Equivalent:

```bash
python -m bjorn_manager
```

## Build (Local)

`build.py` packages for the host OS only.

```bash
python build.py --version 1.2.3
```

Artifacts:

- Windows: `dist/BJORN_Manager_v1.2.3_windows.exe`
- Linux: `dist/BJORN_Manager_v1.2.3_linux`

## Release Automation

Workflow: `.github/workflows/release.yml`

Trigger with a version tag:

```bash
git tag v1.2.3
git push origin v1.2.3
```

Pipeline:

- builds on `windows-latest` and `ubuntu-latest`
- uploads both artifacts
- generates `SHA256SUMS.txt`
- creates GitHub Release with auto-generated notes

## JS <-> Python Contract

Frontend calls backend via `window.pywebview.api.*`.

Common backend methods:

- `start_discovery`
- `connect_ssh` / `disconnect_ssh`
- `upload_files` / `upload_custom_script`
- `install_bjorn`
- `restart_bjorn`, `reboot_target`, `change_epd_type`
- `stream_logs` / `stop_log_stream`
- `get_installation_options` / `generate_custom_installer`

Backend emits events to UI through `BJORNInterface.*` using `JSBridge`.

## Discovery Notes

- Multi-source discovery: mDNS + CIDR scan + port 8000 polling.
- BJORN-focused hostname filtering.
- Interface tags:
  - `172.20.2.x` -> USB
  - `172.20.1.x` -> Bluetooth
  - others -> LAN
- Current behavior keeps discovered devices visible between scans.

## Installer Notes

Default install path:

- upload `assets/install_bjorn.sh`
- upload `assets/lib/*.sh`
- execute remotely with env vars and install mode flag

Advanced path:

- generate temporary custom script with `ScriptGenerator`
- validate shell script with `ScriptValidator`
- upload and execute over SSH

## Security / Operational Notes

- Paramiko currently uses `AutoAddPolicy` (trust-on-first-use host key policy).
- Remote privileged operations run through `sudo`.
- Validate custom scripts carefully before execution.

## Language Persistence

- Windows:
  - primary: `HKCU\\Software\\BJORNManager\\Language` (Registry)
  - fallback: `%APPDATA%\\BJORNManager\\preferences.json`
- Linux:
  - `${XDG_CONFIG_HOME:-~/.config}/bjorn_manager/preferences.json`
- Legacy migration:
  - if present, old `~/.bjorn_manager/preferences.json` is migrated automatically.

## Deeper Documentation

Detailed technical guide:

- `docs/BJORN_MANAGER_DETAILED.md`
