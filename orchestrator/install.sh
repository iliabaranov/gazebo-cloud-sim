#!/usr/bin/env bash
# install.sh — Install gz-sim CLI and health-monitor.
#
# Usage:
#   bash orchestrator/install.sh
#
# What it does:
#   1. Installs Python dependencies (docker, click, rich) via pip
#   2. Symlinks gz-sim and health-monitor into /usr/local/bin
#      (or ~/bin if /usr/local/bin is not writable without sudo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GZ_SIM="${SCRIPT_DIR}/gz-sim"
HEALTH_MON="${SCRIPT_DIR}/health-monitor"

echo "=== gz-sim orchestrator install ==="
echo ""

# ── Python deps ───────────────────────────────────────────────────────────────
echo "Installing Python dependencies..."

# On Ubuntu 22.04/24.04 the system Python is externally managed.
# Prefer apt packages; fall back to pip with --break-system-packages.
APT_PKGS=(python3-docker python3-click python3-rich)
MISSING=()
for pkg in "${APT_PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "  Installing via apt: ${MISSING[*]}"
    apt-get install -y "${MISSING[@]}" 2>/dev/null \
        || python3 -m pip install --break-system-packages --quiet \
               -r "${SCRIPT_DIR}/requirements.txt"
else
    echo "  apt packages already present."
fi

python3 -c "import docker, click, rich" \
    || { echo "ERROR: Python deps missing after install attempt."; exit 1; }
echo "  docker, click, rich — OK."
echo ""

# ── Make scripts executable ───────────────────────────────────────────────────
chmod +x "$GZ_SIM" "$HEALTH_MON"

# ── Symlink to PATH ───────────────────────────────────────────────────────────
if [ -w /usr/local/bin ]; then
    BIN_DIR="/usr/local/bin"
else
    BIN_DIR="$HOME/bin"
    mkdir -p "$BIN_DIR"
    # Remind user to add ~/bin to PATH if not already there
    if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
        echo "  NOTE: Add ~/bin to your PATH:"
        echo "    echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
        echo ""
    fi
fi

ln -sf "$GZ_SIM"     "${BIN_DIR}/gz-sim"
ln -sf "$HEALTH_MON" "${BIN_DIR}/gz-sim-health"

echo "Installed:"
echo "  gz-sim        → ${BIN_DIR}/gz-sim"
echo "  gz-sim-health → ${BIN_DIR}/gz-sim-health"
echo ""
echo "Quick start:"
echo "  gz-sim status"
echo "  gz-sim start --n 3"
echo "  gz-sim --help"
echo ""
echo "Health monitor (run in background):"
echo "  nohup gz-sim-health >> /tmp/gz-health.log 2>&1 &"
echo "  echo \$! > /tmp/gz-health.pid"
echo "  tail -f /tmp/gz-health.log"
