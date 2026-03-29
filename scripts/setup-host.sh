#!/usr/bin/env bash
# setup-host.sh — Prepare an Ubuntu 22.04/24.04 host to run ros2-gazebo containers.
#
# Installs / configures:
#   1. NVIDIA driver (Canonical-signed, Secure Boot compatible)
#   2. Docker CE
#   3. NVIDIA Container Toolkit
#   4. 4 GB swapfile (swappiness=1)
#
# Safe to re-run: each step checks whether it's already done.
# Must be run as root (sudo bash scripts/setup-host.sh).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Run with sudo: sudo bash $0"

UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
info "Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME}), kernel $(uname -r)"

# ── 1. NVIDIA Driver ───────────────────────────────────────────────────────────
info "=== Step 1: NVIDIA Driver ==="

if nvidia-smi &>/dev/null; then
    info "NVIDIA driver already loaded: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
else
    warn "NVIDIA driver not loaded. Attempting install..."

    # Check Secure Boot — DKMS modules won't load if SB is on without MOK enrollment.
    SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    if echo "$SB_STATE" | grep -q "enabled"; then
        warn "Secure Boot is ENABLED. Using Canonical-signed kernel modules (not DKMS)."
        KERNEL=$(uname -r)

        # Find the highest available nvidia driver version for this kernel
        DRIVER_PKG=$(apt-cache search "linux-modules-nvidia.*${KERNEL}" 2>/dev/null \
            | awk '{print $1}' | sort -t- -k4 -V | tail -1)

        if [[ -z "$DRIVER_PKG" ]]; then
            error "No Canonical-signed NVIDIA kernel modules found for kernel ${KERNEL}.
Try: apt-cache search 'linux-modules-nvidia'
You may need to upgrade your kernel or use a different Ubuntu release."
        fi

        DRIVER_VER=$(echo "$DRIVER_PKG" | grep -oP 'nvidia-\K[0-9]+' | head -1)
        info "Installing ${DRIVER_PKG} + nvidia-driver-${DRIVER_VER}"

        apt-get update -qq
        apt-get install -y "${DRIVER_PKG}" "nvidia-driver-${DRIVER_VER}"

        # Remove any DKMS modules that could shadow the canonical ones
        rm -f "/lib/modules/${KERNEL}/updates/dkms/nvidia"*.ko.zst 2>/dev/null || true
        depmod -a

    else
        warn "Secure Boot is OFF or unknown — installing via ubuntu-drivers."
        apt-get update -qq
        apt-get install -y ubuntu-drivers-common
        ubuntu-drivers install
    fi

    # Load modules
    modprobe nvidia    || warn "modprobe nvidia failed — may need a reboot"
    modprobe nvidia-uvm || true

    if nvidia-smi &>/dev/null; then
        info "NVIDIA driver installed and loaded successfully."
    else
        warn "Driver installed but nvidia-smi still fails."
        warn "A REBOOT may be required before continuing."
        warn "After reboot, re-run this script to complete setup."
        exit 0
    fi
fi

# ── 2. Docker CE ───────────────────────────────────────────────────────────────
info "=== Step 2: Docker CE ==="

if docker info &>/dev/null; then
    info "Docker already installed: $(docker --version)"
else
    info "Installing Docker CE..."
    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    info "Docker installed."
fi

# ── 3. NVIDIA Container Toolkit ───────────────────────────────────────────────
info "=== Step 3: NVIDIA Container Toolkit ==="

if docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 \
        nvidia-smi &>/dev/null; then
    info "NVIDIA Container Toolkit already working."
else
    info "Installing NVIDIA Container Toolkit..."

    # Try Ubuntu repos first (works on 24.04), fall back to NVIDIA repo
    if apt-cache show nvidia-container-toolkit &>/dev/null; then
        apt-get install -y nvidia-container-toolkit
    else
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

        curl -s -L \
            "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list

        apt-get update -qq
        apt-get install -y nvidia-container-toolkit
    fi

    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    info "Testing GPU access in Docker..."
    if docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 \
            nvidia-smi &>/dev/null; then
        info "GPU access in Docker: OK"
    else
        error "GPU access in Docker failed. Check nvidia-container-toolkit logs."
    fi
fi

# ── 4. Swapfile ────────────────────────────────────────────────────────────────
info "=== Step 4: Swapfile ==="

if swapon --show | grep -q /swapfile; then
    SWAP_SIZE=$(swapon --show --bytes | awk '/swapfile/ {printf "%.0fG\n", $3/1073741824}')
    info "Swapfile already active (${SWAP_SIZE})."
else
    info "Creating 4 GB swapfile at /swapfile..."
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # Low swappiness: only use swap as last resort
    echo 'vm.swappiness=1' > /etc/sysctl.d/99-swappiness.conf
    sysctl vm.swappiness=1

    info "Swapfile created and activated."
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
info "=== Host setup complete ==="
echo ""
echo "  GPU:    $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "  Docker: $(docker --version)"
echo "  Swap:   $(swapon --show --bytes | awk '/swapfile/ {printf \"%.0f MiB\n\", $3/1048576}')"
echo ""
echo "Next steps:"
echo "  sudo docker compose build          # build image (~10 min)"
echo "  bash scripts/run.sh 5              # start 5 instances"
echo "  bash scripts/verify.sh             # check everything works"
