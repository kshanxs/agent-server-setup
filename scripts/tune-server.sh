#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "======================================================"
echo " Starting Server Tuning & Optimization for Agent Box "
echo "======================================================"

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
echo "Target user: ${TARGET_USER}"

# 1. Stop and disable unneeded background services
echo "[1/6] Disabling unneeded background daemons..."
systemctl stop ModemManager.service 2>/dev/null || true
systemctl disable ModemManager.service 2>/dev/null || true
systemctl mask ModemManager.service 2>/dev/null || true

systemctl stop multipathd.service 2>/dev/null || true
systemctl disable multipathd.service 2>/dev/null || true
systemctl mask multipathd.service 2>/dev/null || true

systemctl stop fwupd.service 2>/dev/null || true
systemctl disable fwupd.service 2>/dev/null || true

# 2. Remove unwanted snaps
echo "[2/6] Removing unwanted snaps (hwctl, lxd)..."
if snap list hwctl &>/dev/null; then
    snap remove hwctl || true
fi
if snap list lxd &>/dev/null; then
    snap remove lxd || true
fi

# 3. Prevent sleep on lid close permanently (for laptop servers)
echo "[3/6] Ensuring lid close does not suspend server..."
mkdir -p /etc/systemd/logind.conf.d
cat << 'EOF' > /etc/systemd/logind.conf.d/ignore-lid.conf
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=no
EOF
# Reload logind config safely without dropping active sessions
systemctl kill -s HUP systemd-logind 2>/dev/null || true

# 4. Install essential CLI tools, system info fetchers & zram-tools
echo "[4/6] Installing CLI utilities (ripgrep, fd, fzf, ncdu, tree, fastfetch, neofetch) & zram-tools..."
apt-get update -y
apt-get install -y --no-install-recommends \
    ripgrep \
    fd-find \
    fzf \
    ncdu \
    tree \
    fastfetch \
    zram-tools

# Symlink fdfind -> fd for standard usage
if command -v fdfind >/dev/null && ! command -v fd >/dev/null; then
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd
fi

# Install neofetch standalone script if not present
if ! command -v neofetch >/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/dylanaraps/neofetch/master/neofetch -o /usr/local/bin/neofetch
    chmod +x /usr/local/bin/neofetch
fi

# Configure zram for in-memory compressed swap (50% RAM, zstd compression)
cat << 'EOF' > /etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl restart zramswap.service 2>/dev/null || service zramswap restart 2>/dev/null || true

# 5. Install Docker & Compose
echo "[5/6] Installing Docker Engine & Compose..."
if ! command -v docker >/dev/null; then
    apt-get install -y docker.io docker-compose-v2 docker-buildx || curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

if id "$TARGET_USER" &>/dev/null; then
    usermod -aG docker "$TARGET_USER"
    echo "Added $TARGET_USER to docker group."
fi

# 6. Ensure passwordless sudo is configured for non-interactive agent execution
echo "[6/6] Ensuring passwordless sudo is configured for $TARGET_USER..."
cat << EOF > "/etc/sudoers.d/${TARGET_USER}"
${TARGET_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "/etc/sudoers.d/${TARGET_USER}"

echo "======================================================"
echo " Server tuning complete! "
echo "======================================================"
