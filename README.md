<div align="center">

# Agent Server Setup

**Turn any Ubuntu Server, homelab box, laptop, or Proxmox instance into a dedicated, high-performance remote AI coding agent workstation.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Ubuntu](https://img.shields.io/badge/Platform-Ubuntu%2022.04%20%7C%2024.04%20%7C%2026.04-orange.svg)](#)
[![Virtualization: Proxmox](https://img.shields.io/badge/Virtualization-Proxmox%20VE-E57000.svg)](docs/proxmox.md)
[![Architecture: Multi-Node](https://img.shields.io/badge/Architecture-Multi--Node%20Deploy-purple.svg)](docs/multi-node-deployment.md)
[![Mesh VPN: Tailscale](https://img.shields.io/badge/VPN-Tailscale-24292e.svg)](https://tailscale.com)

</div>

---

## 🏗️ System Architecture

```mermaid
flowchart TD
    subgraph Clients["Client Devices (Workstations & Mobile)"]
        MAC["MacBook / Laptop"]
        DESK["Linux / Windows Desktop"]
        PHONE["Mobile / Tablet"]
    end

    subgraph Network["Secure Private Mesh Network"]
        TS["Tailscale Mesh VPN (Zero Open Ports)"]
        LAN["Local Gigabit LAN (< 1ms Latency)"]
    end

    subgraph Host["Agent Server Host (Bare Metal / Laptop / Proxmox VE)"]
        subgraph Services["Core Agent Services"]
            T3["T3 Code Server (Nightly on port 3773)"]
            CLAUDE["Claude Code CLI"]
            CODEX["Codex CLI"]
        end

        subgraph Runtimes["Modern Runtimes & Containers"]
            DOCKER["Docker Engine 29.x & Compose v2"]
            VITE["Vite+ Runtime (Node.js 24 + Bun)"]
            UV["uv & uvx (Fast Rust Python)"]
        end

        subgraph Accelerators["CLI & System Accelerators"]
            SEARCH["ripgrep & fd-find"]
            TERM["tmux, fzf & btop"]
            ZRAM["ZRAM (Compressed In-Memory Swap)"]
            LID["Lid Protection (No Suspend on Close)"]
        end
    end

    MAC --> TS
    DESK --> TS
    PHONE --> TS
    MAC --> LAN
    DESK --> LAN

    TS --> T3
    LAN --> T3

    T3 --> Runtimes
    CLAUDE --> Runtimes
    CODEX --> Runtimes

    Runtimes --> Accelerators
```

---

## ⚡ Quick Start

```mermaid
flowchart LR
    A["1. Clone Repo"] --> B["2. Run Tuner Script"]
    B --> C["3. Connect Tailscale"]
    C --> D["4. Start T3 Code / Agents"]
```

Clone this repository and run the automated tuner on your Ubuntu server or VM:

```bash
git clone https://github.com/kshanxs/agent-server-setup.git
cd agent-server-setup
sudo bash tune-server.sh
```

---

## 📂 Repository Structure

```
agent-server-setup/
├── README.md                     # Main project portal & architecture overview
├── LICENSE                       # MIT open source license
├── tune-server.sh                # Root execution wrapper
├── scripts/
│   └── tune-server.sh            # Automated server tuning & provisioning script
└── docs/
    ├── setup.md                  # Comprehensive Ubuntu bare-metal setup guide
    ├── proxmox.md                # Proxmox VE (LXC & VM) deployment guide
    └── multi-node-deployment.md  # Dynamic multi-node LAN deployment guide
```

---

## 📖 Documentation & Guides

| Guide | Description | Target Use Case |
| :--- | :--- | :--- |
| **[Ubuntu Server Setup Guide](docs/setup.md)** | End-to-end installation walkthrough covering base packages, non-interactive sudo, laptop lid policies, ZRAM swap, Docker, Tailscale, runtimes (`uv`, `vite-plus`), and AI agents (**T3 Code**, **Claude Code**, **Codex**). | Bare-metal servers, repurposed laptops, mini-PCs |
| **[Proxmox VE Setup Guide](docs/proxmox.md)** | Guide for deploying dedicated agent nodes in Proxmox VE using lightweight unprivileged **LXC containers** (with Docker nesting & Tailscale tun pass-through) or **KVM VMs** (with Cloud-Init & GPU passthrough). Includes host optimizations. | Homelabs, hypervisors, VM clusters |
| **[Multi-Node LAN Deployment](docs/multi-node-deployment.md)** | Dynamic architecture guide for decoupling **Development / Agent Nodes** from **Production / Database Nodes** on LAN or Tailscale. Covers zero-password SSH key auth, remote Docker contexts (`docker --context`), and GitOps webhooks. | Multi-machine LANs, dedicated DB/App split |
| **[Automated Tuning Script](scripts/tune-server.sh)** | One-click bash script to disable bloat daemons, install Docker, configure in-memory ZRAM swap, install agent CLI utilities (`ripgrep`, `fd`, `fzf`, `ncdu`, `tree`), and ensure continuous operation. | Fast automated provisioning |

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
