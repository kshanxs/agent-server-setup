<img src="assets/icon.svg" width="64" height="64" alt="">

# Server Setup & Fine-Tuning

Dedicated remote AI coding agent and development server configuration on Ubuntu 26.04 LTS.

## Host Specifications
- **Model:** HP Laptop (`hpsayshi`)
- **CPU:** Intel Core i3-4010U (2 cores / 4 threads @ 1.70 GHz)
- **RAM:** 8 GB DDR3 + 3.75 GB compressed ZRAM swap
- **Storage:** 98 GB SSD (LVM)
- **Network:** Wi-Fi (`wlo1`) + Tailscale mesh VPN (`100.98.178.105`)

## Installed Stack & Tools

| Category | Tools | Notes |
| :--- | :--- | :--- |
| **Agent / Server** | `t3` (nightly), `claude`, `codex` | T3 Code server running via systemd user unit on Tailscale port 3773 |
| **Runtimes** | Node.js (v24), npm, Vite+, Python 3, `uv`, `uvx` | High-performance JS & Python toolchains |
| **Containers** | Docker Engine 29.1, Docker Compose v2.40 | Native container runtime; user `nemo` added to `docker` group |
| **CLI & Productivity** | `ripgrep` (`rg`), `fd-find` (`fd`), `fzf`, `ncdu`, `tree`, `tmux`, `jq`, `gh`, `git` | Fast search, fuzzy finding, and terminal workflow |
| **System & Monitoring** | `btop`, `htop`, `powertop`, `zram-tools` | Performance profiling & compressed RAM swap |

## Applied Optimizations
1. **Disabled Unwanted Daemons**:
   - `ModemManager.service`: Masked (cellular modem daemon unused on Wi-Fi).
   - `multipathd.service`: Masked (enterprise SAN storage tool unused on single SSD).
   - `fwupd.service`: Disabled (run manually when upgrading firmware).
2. **Removed Unneeded Snaps**:
   - Removed `hwctl` (Canonical QA test tool).
   - Removed `lxd` (in favor of Docker).
3. **Lid-Close Power Policy**:
   - Configured `/etc/systemd/logind.conf.d/ignore-lid.conf` to ignore lid switch events so the server never suspends when closed.
4. **Memory Optimization**:
   - Enabled **ZRAM** (`/dev/zram0`, 3.75 GB priority 100) using `zstd` compression to prevent disk thrashing under heavy builds.
5. **Codex Background Daemons**:
   - Stopped idle background daemon processes to reclaim ~550 MB RAM.

## Tuning Script
The automated setup script is maintained in [`tune-server.sh`](tune-server.sh).
