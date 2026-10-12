<div align="center">

<img src="assets/icon.svg" width="80" height="80" alt="Agent Server Setup Logo">

# Agent Server Setup

**Turn any Ubuntu Server, homelab box, laptop, or Proxmox instance into a dedicated, high-performance remote AI coding agent workstation.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Ubuntu](https://img.shields.io/badge/Platform-Ubuntu%2022.04%20%7C%2024.04%20%7C%2026.04-orange.svg)](#)
[![Virtualization: Proxmox](https://img.shields.io/badge/Virtualization-Proxmox%20VE-E57000.svg)](proxmox.md)
[![Mesh VPN: Tailscale](https://img.shields.io/badge/VPN-Tailscale-24292e.svg)](https://tailscale.com)

</div>

---

## ⚡ Quick Start

Clone this repository and run the automated tuner on your Ubuntu server or VM:

```bash
git clone https://github.com/kshanxs/agent-server-setup.git
cd agent-server-setup
sudo bash tune-server.sh
```

---

## 📖 Documentation & Guides

* **[Ubuntu Server Setup Guide (`setup.md`)](setup.md)**  
  End-to-end installation walkthrough covering base packages, non-interactive sudo, laptop lid power policies, ZRAM swap, Docker, Tailscale, runtimes (`uv`, `vite-plus`), and AI agents (**T3 Code**, **Claude Code**, **Codex**).

* **[Proxmox VE Setup Guide (`proxmox.md`)](proxmox.md)**  
  Guide for deploying dedicated agent nodes in Proxmox VE using lightweight unprivileged **LXC containers** (with Docker nesting & Tailscale tun pass-through) or **KVM VMs** (with Cloud-Init & GPU passthrough). Includes host-level optimizations.

* **[Automated Tuning Script (`tune-server.sh`)](tune-server.sh)**  
  One-click bash script to disable bloat daemons, install Docker, configure in-memory ZRAM swap, install agent CLI utilities (`ripgrep`, `fd`, `fzf`, `ncdu`, `tree`), and ensure continuous operation.

---

## 🛠️ The Agent Stack

| Layer | Component | Description |
| :--- | :--- | :--- |
| **Agent Daemons** | **T3 Code (Nightly)** | Collaborative browser & editor server running as a persistent systemd service |
| | **Claude Code** | Anthropic's official agentic terminal assistant |
| | **Codex** | Independent agent CLI & developer execution environment |
| **Remote Access** | **Tailscale** | Encrypted WireGuard-based private mesh network with zero open public ports |
| **Containers** | **Docker Engine & Compose** | Containerized services, test environments, and database stacks |
| **Modern Runtimes** | **Vite+ (`vp`)** | High-performance JavaScript/TypeScript runtimes (Node.js & Bun) |
| | **uv & uvx** | Ultra-fast Rust-based Python package manager and runner |
| | **GitHub CLI (`gh`)** | Fast repository management and PR workflows directly from terminal |
| **Performance Tuning** | **ZRAM (`zstd`)** | In-memory compressed RAM swap preventing disk thrashing on heavy agent builds |
| | **Lid Protection** | Prevents suspension on laptop servers when closed or unplugged |
| **CLI Accelerators** | **ripgrep (`rg`)** | Blazing-fast symbol and pattern search across large codebases |
| | **fd-find (`fd`)** | Smart, fast directory and file finding |
| | **fzf** | Interactive command-line fuzzy finder |
| | **btop & htop** | Visual real-time CPU, memory, and process tree monitors |
| | **tmux** | Terminal multiplexer for persistent sessions |

---

## 🔒 Security & Privacy

* **No Credentials Stored**: All configs and scripts are completely generic and use system environment variables (`$USER`, `$SUDO_USER`).
* **Zero Public Port Exposure**: All remote access operates over your private encrypted Tailscale network or local subnet.
* **Non-Root Docker Execution**: Your primary user is placed in the `docker` group for rootless container operations.

---

## 📄 License

MIT License. Feel free to use, modify, and distribute for your own homelab or cloud server setups.
