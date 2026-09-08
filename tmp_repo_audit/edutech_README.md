# 🛡️ Edufwesh Premium VPN Auto-Installer (v4.8.0)

![Version](https://img.shields.io/badge/Version-4.8.0-blue.svg)
![OS](https://img.shields.io/badge/OS-Ubuntu_20.04_|_22.04_|_24.04-green.svg)
![Bash](https://img.shields.io/badge/Language-Bash-yellow.svg)
![Status](https://img.shields.io/badge/Status-Enterprise_Stable-success.svg)

An advanced, all-in-one VPN server deployment script designed for high-performance tunneling, secure access management, and automated maintenance. Built with a robust **HAProxy + Nginx + WS-ePro** multiplexing architecture, allowing multiple protocols to run seamlessly over a single port (443).

---

## ✨ Enterprise Features

### 🌐 Multi-Protocol Support
* **Xray Core:** VLESS, VMess, Trojan, Shadowsocks (WS, gRPC, HTTPUpgrade, XTLS-Reality)
* **SSH / Dropbear:** Native and WebSocket (WS) payload support via custom WS-ePro proxy.
* **OpenVPN:** Dual UDP & TCP configurations (Port 1194).
* **WireGuard & Hysteria2:** Next-gen UDP tunneling protocols.
* **Obfuscation Tools:** SlowDNS (DNSTT), BadVPN-UDPGW, wstunnel, udp2raw, and Squid Proxy.

### 🔒 Advanced Security & Traffic Control
* **DDoS-Deflate Engine:** Aggressive connection limiters to bounce Layer 4 attacks.
* **Automated AutoKill Daemon:** Enforces device limits (multi-login prevention) and instantly terminates expired accounts.
* **Cloud-Safe Firewall:** Blocks P2P/Torrenting traffic, SMTP SPAM (Port 25), and malicious RPC exploitation to keep your VPS provider happy.

### 🤖 Integrated Telegram Bot
Includes a powerful, localized Telegram bot for users and administrators:
* Generate 3-Day Free Trials instantly.
* Real-time server stat monitoring (RAM, CPU, Bandwidth).
* Remote user management (Create, Delete, Extend).

### 🛠️ Long-Term Stability Optimizations
Engineered to run for months without manual intervention:
* **Dynamic Swap Allocation:** Automatically provisions a 2GB swap file to prevent Out-Of-Memory (OOM) crashes.
* **Automated Log Rotation:** Compresses and purges Xray and Proxy logs after 7 days.
* **Nightly Cache Flush:** Silent cron jobs clear ghost RAM (pagecaches).
* **Network Tuning:** TCP BBR congestion control and FQ queueing applied automatically.

---

## 📋 System Requirements

* **Operating System:** Ubuntu 24.04 LTS (Noble Numbat), 22.04 LTS, or 20.04 LTS.
* **Architecture:** AMD64 or ARM64.
* **Privileges:** `root` access required.
* **Domain:** A pointed domain or subdomain (A Record mapped to your VPS IP).

---

## 🚀 Installation

Run the following commands as root on your clean VPS:

    # 1. Update package lists
    apt update && apt upgrade -y

    # 2. Download the installer
    wget -qO setup12.sh https://raw.githubusercontent.com/YourGitHub/YourRepo/main/setup12.sh

    # 3. Make executable and run
    chmod +x setup12.sh
    ./setup12.sh

### Installation Prompts
During installation, you will be asked to provide:
1. **Main Domain:** (e.g., `vpn.yourdomain.com`)
2. **Nameserver Domain:** (e.g., `ns.yourdomain.com` - used for SlowDNS)
3. **Telegram Bot Token:** (Optional, for bot deployment)
4. **Admin Telegram ID:** (Required if using the bot)

---

## 💻 The Neon Pro Menu System

Once installation is complete, simply type `menu` in your terminal to access the interactive UI.

The menu provides full control over your server, including:
* **Protocol Managers:** Individual dashboards for SSH, VMess, VLESS, Trojan, and Shadowsocks.
* **Online Monitor:** Track active SSH and Xray connections in real-time.
* **CDN Bypass Manager:** Easily route traffic through Cloudflare Workers or AWS CloudFront.
* **Domain & SSL Tools:** Force-renew Let's Encrypt certificates or issue Wildcards.
* **Backup Engine:** Export or restore your entire database and configuration files instantly.

---

## 📂 Port Layout Architecture

| Service | Ports | Protocol |
| :--- | :--- | :--- |
| **OpenSSH** | `22` | TCP |
| **Dropbear** | `109`, `143` | TCP |
| **HAProxy (Mux)** | `80`, `443`, `8080`, `2052` | TCP / WS / gRPC |
| **Stunnel4** | `447`, `777` | TLS |
| **XTLS-Reality** | `8443` | TCP |
| **OpenVPN** | `1194` | UDP & TCP |
| **WireGuard** | `51820` | UDP |
| **Squid Proxy** | `3128` | TCP |
| **SlowDNS** | `53` | UDP |

---

## ⚠️ Disclaimer & Terms of Service

This script is designed for educational, enterprise, and private networking purposes.
* **Strict NO Torrenting / P2P Policy.**
* **Strict NO DDoS or malicious network activities.**

The developers are not responsible for any misuse of this software or violations of your Cloud/VPS provider's Terms of Service.

---
*© 2026 Edufwesh Networks. Built for performance. Engineered for stability.*
