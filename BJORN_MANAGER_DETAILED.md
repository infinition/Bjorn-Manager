# BJORN Manager Detailed Technical Guide

This document explains in detail how BJORN Manager works internally, aimed at developers and advanced users.

## 1. High-Level Architecture

BJORN Manager is a desktop app with two main layers:

- Frontend: `bjorn_ui.html` (HTML/CSS/JavaScript).
- Backend: Python package `bjorn_manager`.

Communication model:

- JS -> Python: via `window.pywebview.api.<method>()`.
- Python -> JS: via `JSBridge` queue calling `window.evaluate_js(...)` safely.

Core backend coordinator:

- `BJORNWebAPI` in `bjorn_manager/app.py`.

## 2. Entry Points and Startup

Startup files:

- `run.py`: convenience launcher using `runpy.run_module("bjorn_manager", ...)`.
- `bjorn_manager/__main__.py`: normal Python module entrypoint.
- `bjorn_manager/app.py:main()`: creates the pywebview window and JS API.

Startup sequence:

1. `main()` creates `BJORNWebAPI`.
2. `webview.create_window(...)` starts the app window, binding `js_api=api`.
3. `window.events.loaded += api.on_loaded` ensures backend starts only when DOM is ready.
4. `api.on_loaded()` marks JS bridge ready and starts discovery.

## 3. Backend API Surface (`BJORNWebAPI`)

Main methods exposed to JS:

- Lifecycle/UI: `close_window`, `toggle_fullscreen`, `get_default_ssh_key_path`.
- Discovery: `start_discovery`.
- SSH: `connect_ssh`, `disconnect_ssh`.
- Upload/install: `upload_files`, `upload_custom_script`, `install_bjorn`.
- Advanced config: `get_installation_options`, `generate_custom_installer`.
- Remote actions: `restart_bjorn`, `change_epd_type`, `stream_logs`, `stop_log_stream`, `reboot_target`.
- Diagnostics: `get_system_info`, `get_script_info`, `preview_script`.

Event callback routing from workers to UI happens in `_api_callback(event_type, *args)`.

## 4. Threading and Concurrency Model

### 4.1 Why `JSBridge` exists

Direct concurrent `evaluate_js()` calls from multiple Python threads can race and crash.

`JSBridge` solves this by:

- collecting outbound JS calls in a thread-safe queue,
- running a single consumer thread,
- waiting for window readiness (`mark_ready()`) before flushing calls.

File:

- `bjorn_manager/ui/js_bridge.py`

### 4.2 Worker thread usage

`BJORNWebAPI` dispatches long tasks to daemon threads:

- SSH connect thread,
- upload thread,
- install thread,
- restart/reboot/log-stream helper threads.

This keeps the UI responsive while operations run.

## 5. Discovery Engine (`bjorn_manager/discovery/manager.py`)

Discovery combines 3 mechanisms:

- mDNS browsing (`_ssh._tcp.local.`, `_workstation._tcp.local.`),
- CIDR TCP scanning (default gateway subnet + BJORN USB/Bluetooth ranges),
- periodic port-8000 probing for Web UI status.

### 5.1 Identity, aliases, and dedup

- Device aliasing uses `DeviceAliasManager` (`Bjorn 1`, `Bjorn 2`, ...).
- Internal registry maps stable device keys to IP sets and last-seen timestamps.
- A device can be reported on multiple interfaces (LAN/USB/Bluetooth) using per-IP tags.

### 5.2 BJORN filtering and ignored IPs

- Hostnames are normalized and checked by BJORN naming patterns.
- Gateways, common routers, and host machine IPs are ignored.
- This reduces false positives.

### 5.3 Stale handling behavior

- Discovery has a sweeper that emits `device_gone` for stale entries.
- In current manager behavior, `BJORNWebAPI` intentionally ignores `device_gone` events to keep previously detected devices visible across scans.

## 6. SSH Layer (`bjorn_manager/ssh/worker.py`)

`SSHWorker` handles:

- connection setup,
- file uploads,
- remote command execution,
- install orchestration,
- service operations,
- log streaming.

### 6.1 Authentication strategy

- Key path resolution first (`~/.ssh/id_ed25519`, `id_rsa`, `id_ecdsa` or explicit path).
- If key auth fails, fallback to password (if provided).

### 6.2 Security posture note

- Host key policy is `paramiko.AutoAddPolicy()` (trust unknown host keys automatically).
- This is convenient but not strict host verification.

### 6.3 Installation execution

`run_install(...)`:

- maps UI options to environment variables,
- runs remote install script with `sudo -S ... bash <script> <mode_flag>`,
- streams output line-by-line,
- parses progress from lines like `Step X of Y`,
- sends progress updates to UI.

### 6.4 Log streaming

- Uses `journalctl -fu bjorn.service`.
- Reads channel continuously until stop signal.

## 7. Install Assets and Script Strategy

Install scripts live in:

- `assets/install_bjorn.sh` (orchestrator)
- `assets/lib/*.sh` (modular steps)

Backend uploads these to the target and executes them remotely.

Modes:

- `online`: normal online install.
- `local`: consumes `/home/bjorn/bjorn_packages.tar.gz`.
- `debug`: deploys `Bjorn.zip` into `/home/bjorn/Bjorn`.

## 8. Advanced Configuration and Custom Script Generation

Files:

- `bjorn_manager/installer/script_generator.py`
- `bjorn_manager/installer/validator.py`

Flow:

1. UI requests options via `get_installation_options()`.
2. User customizes package lists/system toggles/snippets.
3. `generate_custom_installer(config)` creates a temporary shell script.
4. Optional upload through `upload_custom_script(...)`.
5. `install_bjorn(...)` executes generated script on target.

Validation:

- shebang required,
- BOM stripping,
- CRLF -> LF normalization,
- optional `bash -n` syntax check on Unix.

## 9. Frontend Responsibilities (`bjorn_ui.html`)

UI handles:

- device cards and selection,
- SSH form and key path UX,
- install mode/file inputs,
- advanced config modal,
- terminal/log rendering with ANSI color parsing,
- progress bar and connection state transitions.

Important integration points:

- Exposes `window.BJORNInterface` functions for backend callback events.
- Calls backend via `window.pywebview.api.*`.

## 10. State Model and Event Flow

Main frontend state:

- `UIState.connected`
- `UIState.devices` (map of discovered devices)
- installation/progress flags

Typical operation flow:

1. Discovery finds device -> backend emits `device_found` -> UI `addDevice`.
2. User clicks device card -> host field prefilled.
3. User connects -> backend starts SSH worker.
4. User uploads assets and launches install.
5. Worker streams logs/progress back to UI.
6. Optional restart/reboot/log stream commands.

## 11. Packaging and Release System

### 11.1 Local packaging (`build.py`)

- Uses PyInstaller (`--onefile --windowed`).
- Bundles `bjorn_ui.html`, icons, install scripts, and assets.
- Artifact naming includes version + platform.
- Supports non-interactive CI mode using `--version`.

### 11.2 GitHub Actions Release

Workflow file:

- `.github/workflows/release.yml`

Trigger:

- push tag matching `v*`.

Pipeline:

1. Build on Windows and Linux runners.
2. Upload both artifacts.
3. Generate `SHA256SUMS.txt`.
4. Create GitHub Release with auto-generated notes (`generate_release_notes: true`).

This ensures users can quickly see newly shipped features/fixes for each version.

## 12. Key Implementation Strengths

- Thread-safe Python -> JS bridge.
- Multi-source discovery with BJORN-specific filtering.
- Non-blocking backend operation via worker threads.
- Flexible install pipeline (default modular scripts + custom generated scripts).
- Automated cross-platform release artifacts.

## 13. Known Limitations and Improvement Ideas

- Host key verification is permissive (`AutoAddPolicy`), not strict.
- Discovery aliases are in-memory by default (not persisted between app runs).
- Frontend is a large single HTML file; could be split for maintainability.
- Custom scripts currently rely on trusted operator input; sandboxing is minimal.

## 14. Developer Onboarding Checklist

1. Install Python deps: `pip install -r requirements.txt`.
2. Run app: `python run.py`.
3. Verify discovery in a test network.
4. Test SSH connect/install against a non-production BJORN target.
5. Build local artifact with `python build.py --version X.Y.Z`.
6. Tag release `vX.Y.Z` to trigger CI release pipeline.

## 15. File Reference Index

- `run.py`
- `bjorn_manager/__main__.py`
- `bjorn_manager/app.py`
- `bjorn_manager/ui/js_bridge.py`
- `bjorn_manager/discovery/manager.py`
- `bjorn_manager/discovery/device.py`
- `bjorn_manager/ssh/config.py`
- `bjorn_manager/ssh/worker.py`
- `bjorn_manager/installer/validator.py`
- `bjorn_manager/installer/script_generator.py`
- `assets/install_bjorn.sh`
- `bjorn_ui.html`
- `build.py`
- `.github/workflows/release.yml`
