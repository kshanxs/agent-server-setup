# Ubuntu Server Setup Guide for Dedicated AI Agent & Remote Dev Box

A complete, production-ready guide to configuring a fresh **Ubuntu Server** (or repurposed laptop/desktop) into a dedicated, high-performance remote coding machine equipped with **Tailscale**, **T3 Code Nightly**, **Claude Code**, **Codex**, **Docker**, modern runtimes (**Vite+**, **uv**), and optimized AI-agent tooling.

---

## 1. Quick Start: All-in-One Automated Setup

If you want to run everything at once on a fresh machine, copy and run this unified script as root (or with `sudo`):

```bash
curl -fsSL https://raw.githubusercontent.com/your-username/server-setup/main/tune-server.sh | sudo bash
```

*(Or follow the step-by-step sections below for full visibility and control).*

---

## 2. Step-by-Step Setup

### Step 1: Base System Update & Essential Packages
Update package lists, upgrade existing packages, and install foundational build and network utilities:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y --no-install-recommends \
    curl \
    wget \
    git \
    unzip \
    build-essential \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https
```

#### Non-Interactive Sudo (Recommended for Remote Agent Automation)
Allows local AI coding agents and automated build scripts to perform package installs without hanging on interactive password prompts:

```bash
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER
sudo chmod 0440 /etc/sudoers.d/$USER
```

---

### Step 2: Hardware, Power & Memory Tuning

#### 1. Prevent Sleep on Lid Close (For Laptop Servers)
If running Ubuntu on a laptop, configure `systemd-logind` to ignore lid-close switches so the server remains active 24/7:

```bash
sudo mkdir -p /etc/systemd/logind.conf.d
cat << 'EOF' | sudo tee /etc/systemd/logind.conf.d/ignore-lid.conf
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=no
EOF

sudo systemctl kill -s HUP systemd-logind 2>/dev/null || true
```

#### 2. Disable Unnecessary Background Daemons
Free up RAM and CPU cycles by disabling services not needed on a dedicated server:

```bash
# Disable cellular modem daemon (not needed on Wi-Fi/Ethernet)
sudo systemctl stop ModemManager.service 2>/dev/null || true
sudo systemctl disable ModemManager.service 2>/dev/null || true
sudo systemctl mask ModemManager.service 2>/dev/null || true

# Disable SAN multipath daemon (not needed on single NVMe/SSD)
sudo systemctl stop multipathd.service 2>/dev/null || true
sudo systemctl disable multipathd.service 2>/dev/null || true
sudo systemctl mask multipathd.service 2>/dev/null || true

# Disable continuous firmware daemon (run on-demand when updating firmware)
sudo systemctl stop fwupd.service 2>/dev/null || true
sudo systemctl disable fwupd.service 2>/dev/null || true
```

#### 3. Enable In-Memory Compressed Swap (ZRAM)
ZRAM creates an in-memory compressed swap device (zstd). When AI agents or npm builds trigger high memory usage, memory is compressed into RAM rather than thrashing slow disk swap:

```bash
sudo apt install -y zram-tools

cat << 'EOF' | sudo tee /etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF

sudo systemctl restart zramswap.service
```

---

### Step 3: Networking & Secure Remote Access (Tailscale)

Install Tailscale to enable zero-config, encrypted mesh access from your laptop, tablet, or phone without exposing ports to the public internet:

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate and connect
sudo tailscale up

# Note your Tailscale IP
tailscale ip -4
```

---

### Step 4: Containerization (Docker & Docker Compose)

Install Docker Engine and the native Compose v2 plugin:

```bash
sudo apt install -y docker.io docker-compose-v2 docker-buildx
sudo systemctl enable --now docker

# Add your user to the docker group (allows running docker without sudo)
sudo usermod -aG docker $USER
```

> **Note:** Apply the group change immediately in your current shell by running:
> ```bash
> newgrp docker
> ```

---

### Step 5: High-Performance Language Runtimes

#### 1. Vite+ (`vp`, Node.js & Bun)
Vite+ provides high-performance JavaScript/TypeScript runtimes, bundling modern Node.js and Bun:

```bash
curl -fsSL https://vite.plus | bash
source "$HOME/.config/vite-plus/env"
```

Verify:
```bash
vp --version
node --version
npm --version
```

#### 2. `uv` & `uvx` (Ultra-Fast Python)
Astral's `uv` replaces `pip`, `pip-tools`, and `virtualenv` with a 10-100x faster Rust-based implementation:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env" 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"
```

Verify:
```bash
uv --version
uvx --version
```

#### 3. GitHub CLI (`gh`)
```bash
type -p wget >/dev/null || sudo apt install -y wget
sudo mkdir -p -m 755 /etc/apt/keyrings
out=$(mktemp)
wget -nv -O "$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
sudo install -m 644 "$out" /etc/apt/keyrings/githubcli-archive-keyring.gpg
rm -f "$out"
sudo mkdir -p -m 755 /etc/apt/sources.list.d
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install -y gh

# Authenticate with GitHub
gh auth login
```

---

### Step 6: AI Coding Agent CLI Tools

#### 1. Claude Code CLI
Install Anthropic's official terminal coding agent:

```bash
npm install -g @anthropic-ai/claude-code
# Or install via the official standalone script:
# curl -fsSL https://claude.ai/install.sh | bash
```

Verify:
```bash
claude --version
```

#### 2. Codex CLI
Install Codex standalone agent CLI:

```bash
npm install -g @codex-ai/cli
```

Verify:
```bash
codex --version
```

#### 3. T3 Code Nightly (Remote Server & Daemon)
Install T3 Code Nightly and configure it as a persistent systemd user service that automatically starts on boot and runs over your private Tailscale network.

```bash
# Install T3 Code nightly
npm install -g t3@nightly
```

Create the user systemd unit:
```bash
mkdir -p ~/.config/systemd/user
TS_IP=$(tailscale ip -4)

cat << EOF > ~/.config/systemd/user/t3-serve.service
[Unit]
Description=T3 Code Server (Nightly)
After=network-online.target tailscaled.service

[Service]
Type=simple
Environment=PATH=$HOME/.local/share/vite-plus/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$(which t3) serve --no-browser --host $TS_IP $HOME
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

# Enable lingering so user services run even when no SSH session is active
loginctl enable-linger $USER

# Reload and start the T3 Code service
systemctl --user daemon-reload
systemctl --user enable --now t3-serve.service
```

Check status:
```bash
systemctl --user status t3-serve.service
```

---

### Step 7: Essential Productivity & Agent Utilities

Install fast search, navigation, terminal multiplexing, and resource monitoring tools that enhance agent efficiency:

```bash
sudo apt install -y --no-install-recommends \
    ripgrep \
    fd-find \
    fzf \
    ncdu \
    tree \
    tmux \
    jq \
    btop \
    htop \
    powertop

# Symlink fdfind to fd for standard CLI compatibility
if command -v fdfind >/dev/null && ! command -v fd >/dev/null; then
    sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
fi
```

#### Why These Specific Tools Matter for AI Agents:
* **`ripgrep` (`rg`)**: Search massive codebases in milliseconds. AI agents use this heavily for symbol & pattern discovery.
* **`fd-find` (`fd`)**: Fast, intelligent alternative to `find` with default `.gitignore` awareness.
* **`fzf`**: Interactive fuzzy finder for navigating paths, commands, and git commits.
* **`tmux`**: Keeps long-running agent tasks and server commands active even if SSH drops.
* **`ncdu`**: Fast interactive disk usage analyzer to inspect build artifacts, docker caches, and logs.
* **`btop` & `htop`**: Real-time visual monitoring of CPU cores, memory pressure, and process trees.
* **`powertop`**: Hardware power profiling and battery health diagnostics.

---

## 3. System Verification Checklist

Run this quick command block to verify every tool in the stack:

```bash
echo "=== Tool Verification ==="
printf "%-15s: %s\n" "Tailscale" "$(tailscale ip -4 2>/dev/null || echo 'Not connected')"
printf "%-15s: %s\n" "Docker" "$(docker --version 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "Docker Compose" "$(docker compose version 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "Node.js" "$(node --version 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "Vite+ (vp)" "$(vp --version 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "uv" "$(uv --version 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "GitHub CLI" "$(gh --version 2>/dev/null | head -n1 || echo 'Missing')"
printf "%-15s: %s\n" "Claude Code" "$(claude --version 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "Codex" "$(codex --version 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "T3 Code Service" "$(systemctl --user is-active t3-serve.service 2>/dev/null || echo 'Inactive')"
printf "%-15s: %s\n" "ripgrep (rg)" "$(rg --version 2>/dev/null | head -n1 || echo 'Missing')"
printf "%-15s: %s\n" "fd" "$(fd --version 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "btop" "$(which btop 2>/dev/null || echo 'Missing')"
printf "%-15s: %s\n" "ZRAM Swap" "$(cat /proc/swaps | grep zram >/dev/null && echo 'Active' || echo 'Inactive')"
echo "========================="
```

---

## 4. Maintenance & Useful Commands

| Task | Command |
| :--- | :--- |
| **Check Resource Usage** | `btop` or `htop` |
| **Monitor T3 Code Server Logs** | `journalctl --user -u t3-serve.service -f` |
| **Restart T3 Code Server** | `systemctl --user restart t3-serve.service` |
| **Update T3 Code to Latest Nightly**| `npx t3 update --channel nightly && systemctl --user restart t3-serve.service` |
| **Prune Unused Docker Objects** | `docker system prune -af --volumes` |
| **Check ZRAM Compression Ratio** | `zramctl` |
| **Analyze Disk Space** | `ncdu /` |
