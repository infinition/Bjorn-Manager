# <img src="https://github.com/user-attachments/assets/9cd52e7f-637d-45ad-94b8-07b1a93277a6" alt="bjorn" width="120"> BJORN Manager

![Python](https://img.shields.io/badge/Python-3776AB?logo=python&logoColor=fff)
![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux-informational)
![Status](https://img.shields.io/badge/Status-Community%20Test%20Build-blue)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[![Reddit](https://img.shields.io/badge/Reddit-Bjorn__CyberViking-orange?style=for-the-badge&logo=reddit)](https://www.reddit.com/r/Bjorn_CyberViking)
[![Discord](https://img.shields.io/badge/Discord-Join%20Us-7289DA?style=for-the-badge&logo=discord)](https://discord.com/invite/B3ZH9taVfT)

> **What is it?**
> **BJORN Manager** is a desktop companion for the **Bjorn** project that discovers devices on your network/USB/Bluetooth, then helps you **install, update, and control** Bjorn from a single UI.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Download and Launch](#download-and-launch)
- [Quick Start (Recommended)](#quick-start-recommended)
- [How Discovery Works](#how-discovery-works)
- [Troubleshooting](#troubleshooting)
- [Contributing and Feedback](#contributing-and-feedback)
- [License](#license)

---

## Features

- Auto-discovery of Bjorn devices on:
  - LAN
  - USB gadget (`172.20.2.x`)
  - Bluetooth network (`172.20.1.x`)
- Multilingual UI (I18n):
  - English (default), French, Italian, Spanish, German, Chinese, Russian
  - Language can be changed from the bottom-left selector
  - Language choice is remembered between launches
- Smart device naming (`Bjorn 1`, `Bjorn 2`, ...)
- Stable device list between scan cycles
- Install workflows:
  - Online
  - Local package archive
  - Debug bundle
  - Optional advanced/custom installer
- Remote controls:
  - Restart Bjorn service
  - Reboot target
  - Change EPD type
  - Live logs
- More Actions behavior:
  - If an action requires SSH and you are not connected yet, Manager attempts to connect automatically first

## Requirements

- Windows 10/11 or Linux desktop
- Target Raspberry Pi reachable on your network
- SSH enabled on target
- For hostname discovery: mDNS (UDP 5353) should be allowed

## Download and Launch

- Download the latest release artifact for your OS.
- Windows: run the `.exe`.
- Linux:
  - Preferred: install the `.deb`
    - PC Linux (x86_64): `sudo apt install ./bjorn-manager_<version>_amd64.deb`
    - launch with app menu or `bjorn-manager`
  - Alternative: standalone binary
    - x86_64: `BJORN_Manager_v<version>_linux`
    - `chmod +x <binary>` then `./<binary>`
- Linux GUI runtime note:
  - BJORN Manager uses `pywebview`, which needs a GUI backend.
  - The `.deb` declares required dependencies on Debian/Ubuntu.
  - Current release `.deb` uses the Qt backend by default.
  - If launch fails on a minimal Linux desktop, install missing runtime libs:
    - `sudo apt install -y libglib2.0-0 libnss3 libx11-6 libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 libxtst6 libxkbcommon-x11-0 libdbus-1-3 libasound2`
  - The `.deb` launcher sets `PYWEBVIEW_GUI=qt` and `QT_API=pyqt6` unless already defined.
  - Manual debug launch:
    - `PYWEBVIEW_GUI=qt QT_API=pyqt6 bjorn-manager`
    - if it still fails, run `ldd /usr/lib/bjorn-manager/bjorn-manager-bin | grep "not found"`
- Allow firewall access on first launch if prompted.

## Quick Start (Recommended)

1. Prepare your Pi:
   - enable SSH
   - use a Bjorn-compatible hostname (`bjorn`, `bjorn-...`)
2. Launch BJORN Manager and wait for detected devices.
3. Click a device card to auto-fill target host.
4. Choose install settings (EPD, mode, options).
5. Connect, then install.
6. Watch progress and logs in the terminal panel.

## How Discovery Works

- mDNS + SSH probing + periodic WebUI checks
- Discovery/diagnostic backend logs shown in the terminal are localized by UI language when possible
- Interface tags:
  - `172.20.2.x` -> `USB`
  - `172.20.1.x` -> `Bluetooth`
  - others -> `LAN`
- Same Bjorn device across multiple interfaces keeps the same alias index.

## Troubleshooting

- No devices found:
  - verify SSH is enabled
  - verify network/firewall access
  - verify target hostname is Bjorn-compatible
- Install fails:
  - check internet access (online mode)
  - verify SSH credentials
  - retry with a fresh image if needed
- Web UI icon missing:
  - test `http://<target-ip>:8000/`
  - restart service or reboot from Manager

## Contributing and Feedback

Issues and pull requests are welcome.

For bug reports, include:

- Pi model and OS
- connection path (LAN/USB/Bluetooth)
- EPD version
- relevant logs/screenshots

## License

MIT. See `LICENSE`.

---

BJORN Manager is part of the Bjorn ecosystem. Use only on systems and networks you own or are explicitly authorized to test.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=infinition/Bjorn-Manager&type=Date)](https://www.star-history.com/#infinition/Bjorn-Manager&Date)
