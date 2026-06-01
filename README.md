<img src="https://github.com/user-attachments/assets/9cd52e7f-637d-45ad-94b8-07b1a93277a6" alt="Bjorn Manager" width="120">

# Bjorn Manager

[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) ![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white) ![Windows](https://img.shields.io/badge/Windows-0078D4?style=flat&logo=windows&logoColor=white) ![Linux](https://img.shields.io/badge/Linux-FCC624?style=flat&logo=linux&logoColor=black) [![Release](https://img.shields.io/github/v/release/infinition/Bjorn-Manager?style=flat)](https://github.com/infinition/Bjorn-Manager/releases) [![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/infinition)

A desktop companion for the Bjorn project. Discovers Bjorn devices on your network (LAN, USB gadget, Bluetooth) and lets you install, update, and control them from a single UI.

Platforms: Windows, Linux.

Community: [Reddit](https://www.reddit.com/r/Bjorn_CyberViking) | [Discord](https://discord.com/invite/B3ZH9taVfT)

---

## Features

- Auto-discovery over LAN, USB gadget (`172.20.2.x`), and Bluetooth (`172.20.1.x`).
- Multilingual UI: English, French, Italian, Spanish, German, Chinese, Russian. Language persists between launches.
- Smart device naming (Bjorn 1, Bjorn 2, ...) with stable identities across scan cycles.
- Install and update Bjorn over SSH from the UI.
- Terminal panel for live install logs.
- Configurable EPD model, install mode, and options.

---

## Download and run

Grab the latest release from the GitHub Releases page.

**Linux:**

```bash
chmod +x bjorn-manager-*.AppImage
./bjorn-manager-*.AppImage
```

If it fails, check:

```bash
ldd /usr/lib/bjorn-manager/bjorn-manager-bin | grep "not found"
```

Allow firewall access on first launch if prompted.

---

## Quick start

1. Enable SSH on your Pi and use a Bjorn-compatible hostname (`bjorn`, `bjorn-*`).
2. Launch Bjorn Manager and wait for discovered devices.
3. Click a device card to auto-fill the target host.
4. Choose install settings.
5. Connect, then install.

---

## Discovery

- mDNS + SSH probing + periodic WebUI checks.
- Interface tags: `172.20.2.x` = USB, `172.20.1.x` = Bluetooth, others = LAN.
- The same Bjorn device appearing on multiple interfaces keeps the same alias.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| No devices found | Verify SSH is enabled, check firewall, verify hostname |
| Install fails | Check internet access (online mode), verify SSH credentials, try a fresh image |
| Web UI icon missing | Test `http://<target-ip>:8000/`, restart service or reboot from Manager |

For bug reports include: Pi model and OS, connection path, EPD version, logs and screenshots.

---

## Star History

<a href="https://www.star-history.com/?repos=infinition%2FBjorn-Manager&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=infinition/Bjorn-Manager&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=infinition/Bjorn-Manager&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=infinition/Bjorn-Manager&type=date&legend=top-left" />
 </picture>
</a>

---

## License

MIT. See [LICENSE](LICENSE).

Bjorn Manager is part of the Bjorn ecosystem. Use only on systems and networks you own or are explicitly authorized to test.
