#!/usr/bin/env bash
# run.sh — Start N TurtleBot3 NAV2 simulation instances.
#
# Usage:
#   bash scripts/run.sh          # start 5 instances (default)
#   bash scripts/run.sh 3        # start 3 instances
#   bash scripts/run.sh 9        # maximum before CPU saturation on 8-core VM
#
# Each instance N gets:
#   noVNC (browser):  http://<host-ip>:$((8079+N))/vnc.html?autoconnect=true&resize=scale
#   Raw VNC port:     $((5899+N))
#   ROS_DOMAIN_ID:    N
#   GZ_PARTITION:     sim_N  (gz-transport isolation)

set -euo pipefail

IMAGE="ros2-gazebo-gazebo:latest"
N="${1:-5}"
SETTLE_SECS=5   # just check they started; verify.sh does the deep check

# Validate argument
if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 [N]   (N = number of instances, default 5)" >&2
    exit 1
fi

# Check image exists
if ! sudo docker image inspect "$IMAGE" &>/dev/null; then
    echo "Image '$IMAGE' not found. Build it first:" >&2
    echo "  sudo docker compose build" >&2
    exit 1
fi

# Check for DRI devices
for dev in /dev/dri/card0 /dev/dri/renderD128; do
    if [[ ! -e "$dev" ]]; then
        echo "WARNING: $dev not found. GPU passthrough may not work." >&2
    fi
done

echo "Starting $N simulation instance(s)..."
echo ""

STARTED=0
for i in $(seq 1 "$N"); do
    HTTP=$((8079 + i))
    VNC=$((5899 + i))
    NAME="gz_${i}"

    # Skip if already running
    if sudo docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
        echo "  [${i}] ${NAME} already running — skipping"
        continue
    fi

    # Remove stopped container with same name if present
    sudo docker rm "${NAME}" &>/dev/null || true

    sudo docker run -d \
        --name "${NAME}" \
        --runtime=nvidia \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e NVIDIA_DRIVER_CAPABILITIES=all \
        -e DISPLAY=:99 \
        -e "ROS_DOMAIN_ID=${i}" \
        -e VGL_DISPLAY=/dev/dri/card0 \
        -e VGL_REFRESHRATE=60 \
        -e "__EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d/" \
        --device /dev/dri/card0:/dev/dri/card0 \
        --device /dev/dri/renderD128:/dev/dri/renderD128 \
        -p "${HTTP}:8080" \
        -p "${VNC}:5900" \
        "$IMAGE" \
        ros2 launch tb3_sim tb3_nav2.launch.py \
        > /dev/null

    echo "  [${i}] ${NAME} started — noVNC: http://localhost:${HTTP}/vnc.html?autoconnect=true&resize=scale"
    STARTED=$((STARTED + 1))
done

echo ""
echo "$STARTED new instance(s) launched. Total running:"
sudo docker ps --filter "name=gz_" --format "  {{.Names}}  ({{.Status}})"

# Detect host IP for user-friendly URLs (prefer tailscale, fall back to first non-loopback)
HOST_IP=$(ip -4 addr show tailscale0 2>/dev/null | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1)
if [[ -z "$HOST_IP" ]]; then
    HOST_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1)
fi
HOST_IP="${HOST_IP:-localhost}"

echo ""
echo "Access URLs (${HOST_IP}):"
for i in $(seq 1 "$N"); do
    HTTP=$((8079 + i))
    echo "  Instance ${i}: http://${HOST_IP}:${HTTP}/vnc.html?autoconnect=true&resize=scale"
done

echo ""
echo "NAV2 takes ~30s to initialise. Then run:"
echo "  bash scripts/verify.sh"
