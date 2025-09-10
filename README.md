# <img src="https://github.com/user-attachments/assets/9cd52e7f-637d-45ad-94b8-07b1a93277a6" alt="bjorn" width="150"> BJORN Manager

![Python](https://img.shields.io/badge/Python-3776AB?logo=python\&logoColor=fff)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-informational)
![Status](https://img.shields.io/badge/Status-Community%20Test%20Build-blue)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[![Reddit](https://img.shields.io/badge/Reddit-Bjorn__CyberViking-orange?style=for-the-badge\&logo=reddit)](https://www.reddit.com/r/Bjorn_CyberViking)
[![Discord](https://img.shields.io/badge/Discord-Join%20Us-7289DA?style=for-the-badge\&logo=discord)](https://discord.com/invite/B3ZH9taVfT)


> **What is it?**
> **BJORN Manager** is a desktop companion for the **Bjorn** project that discovers devices on your network/USB, shows them in a simple UI, and lets you **install / update / control** Bjorn  with a few clicks.

> **Heads-up (test build):** this version is patched to work with the current public Bjorn, but it’s primarily targeting the next release. You might see harmless warnings or rough edges during install.

---


<img width="1376" height="1126" alt="image" src="https://github.com/user-attachments/assets/6429b426-bdd9-447c-a55a-7f0381deda1e" />
<img width="1378" height="1158" alt="image" src="https://github.com/user-attachments/assets/e9ff9584-c117-443e-b011-f9cd01a36c14" />
<img width="1381" height="1160" alt="image" src="https://github.com/user-attachments/assets/fa3fe655-9c30-492f-aa3e-dad303854af8" />



## 📚 Table of Contents

* [Features](#-features)
* [Requirements](#-requirements)
* [Download & Launch](#-download--launch)
* [Quick Start (Recommended)](#-quick-start-recommended)
* [How Discovery Works](#-how-discovery-works)
* [Troubleshooting](#-troubleshooting)
* [Build From Source](#-build-from-source)
* [Contributing & Feedback](#-contributing--feedback)
* [License](#-license)

---

## 🌟 Features

* **Zero-config discovery**
  Auto-finds Bjorn devices via:

  * **LAN** (mDNS/SSH),
  * **USB gadget (RNDIS)** → `172.20.2.x` (tagged **USB**),
  * **Bluetooth network** → `172.20.1.x` (tagged **Bluetooth**).

* **Smart aliasing & numbering**
  Devices named `bjorn*` get persistent names like **“Bjorn 1”**, **“Bjorn 2”**…
  USB+LAN for the *same* device share the **same number** (no duplicates). Numbering starts at **1**.


* **One-click install**

  * Online install (default)
  * Local/Debug payloads (zip/tar.gz)
  * Optional **custom installer script** (advanced)

* **\_controls**

  * Change EPD type
  * Restart Bjorn systemd service
  * Tail live logs
  * Reboot target

* **Safety & logs**
  Clear progress steps, persistent log file, and coarse error shielding.

---

## 🧰 Requirements

* **Windows 10/11 (x64)**
* Network where your Pi(s) are reachable, plus:

  * **mDNS** allowed (UDP **5353**) if you want auto-discovery by hostname
  * Windows Firewall allows the app to listen/scan locally
* Raspberry Pi imaged with **Raspberry Pi OS , hostname set to **`bjorn`** (via Raspberry Pi Imager “Advanced Options”), **SSH enabled**

> **USB gadget note:** fresh images that expose RNDIS over USB should show up as `172.20.2.x`.

---

## ⬇️ Download & Launch

* Grab the latest **BJORNManager.exe**
* Double-click to run.
  First launch may trigger a **Windows Firewall** prompt → allow access for local network discovery.

---

## ⚡ Quick Start (Recommended)

1. **Prepare your Pi**

   * Fresh Raspberry Pi OS (Bookworm)
   * Set **hostname = `bjorn`**
   * **Enable SSH**
   * (Optional) Connect the **2.13" e-Paper** HAT

2. **Launch BJORN Manager**
   Wait \~**10 seconds**. Detected devices will appear:

   * `LAN` → regular network
   * `USB` → `172.20.2.x` (gadget/RNDIS)
   * `Bluetooth` → `172.20.1.x` (PAN)

3. **Pick your target**

   * Click a device card → the **IP auto-fills**
   * Select your **EPD** version
   * **Install Mode**: keep **Online** for this test
   * **Mode**: choose **AI** (auto-search for targets at boot) or **Manual**

4. **Connect → Install BJORN**
   Watch the log panel for progress (it shows **Step X of Y**).
   When done, the web app (port **8000**) will be detected and a small icon will appear on the Bjorn card.

5. **Share feedback** 🎯
   What worked? What didn’t? Errors, screenshots, logs → super helpful!

---

## 🧭 How Discovery Works

* **Hostname filter**: only hosts whose reverse name looks like `bjorn`, `bjorn.local`, `bjorn-something.local` are considered “Bjorn”.
* **Interface tagging**:

  * `172.20.2.x` → **USB**
  * `172.20.1.x` → **Bluetooth**
  * everything else → **LAN**
* **Unified aliasing**: the same device seen on multiple paths (e.g., USB + LAN) will be shown as **“Bjorn N (USB)”** and **“Bjorn N (LAN)”**, sharing the **same N**.
* **Incremental updates**: the list refreshes **in place**—no flicker, just adds/removes deltas.

---

## 🛠️ Troubleshooting

* **No devices after \~15s**

  * Ensure the Pi’s **hostname is `bjorn`**, not `raspberrypi`
  * **SSH enabled**, same subnet, no VPN blocking local discovery
  * If using **USB**, confirm Windows installed the **RNDIS** driver and the interface shows an IP like `172.20.2.x`

* **Install fails early**

  * Double-check Internet connectivity (for **Online** mode)
  * Re-run from the **console build** to capture full logs (`_console.exe`)
  * Try again on a **fresh image**

* **Web UI icon never appears**

  * Port **8000** may be blocked; try to open `http://<device-ip>:8000/` manually
  * Service restart from the Manager, or reboot the Pi




---

## 🤝 Contributing & Feedback

* **Issue reports / PRs** are welcome!
* Hack on the discovery logic, UI, or installer workflow.

When reporting a bug, include:

* Pi model, OS (32/64-bit), EPD version
* Connection type (LAN / USB / Bluetooth)
* Screenshots and relevant log lines

---

## 📜 License

**MIT** — see [LICENSE](LICENSE).

---

**Bjorn Manager** is part of the **Bjorn** ecosystem. Use responsibly and only on networks/devices you own or have permission to test.



## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=infinition/Bjorn-Manager&type=Date)](https://www.star-history.com/#infinition/Bjorn-Manager&Date)
