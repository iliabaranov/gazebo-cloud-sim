#!/usr/bin/env bash
# capacity-test.sh — Ramp up simulation instances one at a time, measuring
# CPU / RAM / GPU at each step. Stops when RAM drops below 500 MiB free.
#
# Usage:
#   bash scripts/capacity-test.sh          # ramp up to 12 instances (default)
#   bash scripts/capacity-test.sh 8        # stop at 8 instances
#
# All test containers are named gz_cap_N and cleaned up on exit.

set -euo pipefail

IMAGE="ros2-gazebo-gazebo:latest"
MAX="${1:-12}"
SETTLE_SECS=40    # seconds to wait after launch before sampling (NAV2 init)
STOP_FREE_MIB=500 # stop if available RAM drops below this

trap cleanup EXIT

cleanup() {
    echo ""
    echo "Cleaning up test containers..."
    # shellcheck disable=SC2046
    sudo docker stop $(sudo docker ps -q --filter "name=gz_cap_") 2>/dev/null || true
    sudo docker rm   $(sudo docker ps -aq --filter "name=gz_cap_") 2>/dev/null || true
    echo "Done."
}

if ! sudo docker image inspect "$IMAGE" &>/dev/null; then
    echo "Image '$IMAGE' not found. Build it first:" >&2
    echo "  sudo docker compose build" >&2
    exit 1
fi

echo "=== ROS2 Gazebo Capacity Test ==="
echo "Image:       $IMAGE"
echo "Max:         $MAX instances"
echo "Settle time: ${SETTLE_SECS}s per instance"
echo ""

# ── Baseline ─────────────────────────────────────────────────────────────────
echo "--- Baseline (no instances) ---"
free -m | awk '/Mem:/ {printf "RAM: %d MiB used / %d MiB total (%.0f%%)\n", $3, $2, $3/$2*100}'
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu \
    --format=csv,noheader 2>/dev/null \
    | awk -F', ' '{printf "GPU: %s VRAM / %s total, %s util\n", $1, $2, $3}' || true
echo ""

# ── Ramp up ───────────────────────────────────────────────────────────────────
for i in $(seq 1 "$MAX"); do
    HTTP=$((8079 + i))
    VNC=$((5899 + i))
    NAME="gz_cap_${i}"

    echo "--- Launching instance ${i} (noVNC :${HTTP}, VNC :${VNC}) ---"

    sudo docker run -d \
        --name "$NAME" \
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

    echo "  Waiting ${SETTLE_SECS}s to settle..."
    sleep "$SETTLE_SECS"

    echo "  --- Measurements with ${i} instance(s) ---"

    # Per-container stats
    sudo docker stats --no-stream \
        --format "    {{.Name}}: CPU={{.CPUPerc}}  MEM={{.MemUsage}}" \
        $(sudo docker ps -q --filter "name=gz_cap_") 2>/dev/null || true

    # Totals
    TOTAL_CPU=$(sudo docker stats --no-stream --format "{{.CPUPerc}}" \
        $(sudo docker ps -q) 2>/dev/null \
        | awk -F'%' '{s+=$1} END{printf "%.1f%%", s}')

    TOTAL_RAM=$(free -m | awk '/Mem:/ {
        used=$3; total=$2
        printf "%d MiB used / %d MiB total (%.0f%%)", used, total, used/total*100
    }')

    echo "  Total CPU:  $TOTAL_CPU"
    echo "  System RAM: $TOTAL_RAM"

    nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu \
        --format=csv,noheader 2>/dev/null \
        | awk -F', ' '{printf "  GPU:        %s VRAM / %s total, %s util\n", $1, $2, $3}' || true

    LOAD=$(awk '{print $1}' /proc/loadavg)
    NCPU=$(nproc)
    echo "  Load avg:   ${LOAD} (${NCPU} CPUs)"

    # Check realtime factor on last instance as a health indicator
    RTF=$(sudo docker exec "$NAME" bash -c "
        GZ_PARTITION=sim_${i} timeout 6 ign topic -e -t /stats 2>/dev/null \
          | grep 'real_time_factor' | grep -oP '[-0-9.]+' \
          | awk '{s+=\$1;n++} END{if(n>0) printf \"%.3f\",s/n; else print \"N/A\"}'
    " 2>/dev/null || echo "N/A")
    echo "  RTF (gz_cap_${i}): ${RTF}"

    # Stop if RAM is critically low
    FREE_MIB=$(free -m | awk '/Mem:/ {print $4 + $6}')
    if [[ "$FREE_MIB" -lt "$STOP_FREE_MIB" ]]; then
        echo ""
        echo "  *** RAM critically low (${FREE_MIB} MiB available) — stopping at ${i} instances ***"
        break
    fi

    # Stop if RTF has dropped badly (simulation can't keep up)
    if [[ "$RTF" != "N/A" ]] && awk "BEGIN{exit !($RTF < 0.80)}"; then
        echo ""
        echo "  *** RTF dropped to ${RTF} — system overloaded. Stopping at ${i} instances ***"
        break
    fi

    echo ""
done

echo "=== Capacity test complete ==="
sudo docker ps --filter "name=gz_cap_" --format "  {{.Names}}  {{.Status}}"
