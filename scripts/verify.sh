#!/usr/bin/env bash
# verify.sh — Verify running gz_ simulation containers.
#
# Checks for each running instance:
#   - Gazebo server is publishing (ign topic /stats → realtime factor)
#   - Key ROS2 topics exist (/scan, /camera/image_raw, /imu, /odom)
#   - Sensor publication rates (15-second message-count window)
#   - Takes a screenshot and saves to /tmp/gz_<N>_screen.png on the host
#
# Usage:
#   bash scripts/verify.sh           # check all gz_* containers
#   bash scripts/verify.sh gz_1      # check a specific container

set -euo pipefail

MEASURE_SECS=15          # window for message-count rate measurement
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}PASS${NC}  $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${CYAN}INFO${NC}  $*"; }

if [[ $# -gt 0 ]]; then
    CONTAINERS=("$@")
else
    mapfile -t CONTAINERS < <(sudo docker ps --filter "name=gz_" --format "{{.Names}}" | sort)
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo "No running gz_ containers found. Start them first:"
    echo "  bash scripts/run.sh 5"
    exit 1
fi

echo "Verifying ${#CONTAINERS[@]} container(s): ${CONTAINERS[*]}"
echo "Measurement window: ${MEASURE_SECS}s per container"
echo ""

for CONTAINER in "${CONTAINERS[@]}"; do
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN} Container: ${CONTAINER}${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"

    # Extract instance number from container name (gz_1 → 1)
    INSTANCE=$(echo "$CONTAINER" | grep -oP '\d+$' || echo "?")
    GZ_PARTITION="sim_${INSTANCE}"

    # ── Gazebo server process ─────────────────────────────────────────────────
    if sudo docker exec "$CONTAINER" pgrep -f "ign gazebo" &>/dev/null; then
        pass "Gazebo server process running"
    else
        fail "Gazebo server process NOT found"
    fi

    # ── Realtime factor ───────────────────────────────────────────────────────
    RTF=$(sudo docker exec "$CONTAINER" bash -c "
        GZ_PARTITION=${GZ_PARTITION} timeout 6 ign topic -e -t /stats 2>/dev/null \
          | grep 'real_time_factor' | grep -oP '[-0-9.]+' \
          | awk '{s+=\$1;n++} END{if(n>0) printf \"%.4f\",s/n; else print \"N/A\"}'
    " 2>/dev/null || echo "N/A")

    if [[ "$RTF" == "N/A" ]]; then
        fail "Realtime factor: N/A (server not publishing /stats)"
    elif awk "BEGIN{exit !($RTF >= 0.95)}"; then
        pass "Realtime factor: ${RTF} (≥ 0.95 ✓)"
    else
        fail "Realtime factor: ${RTF} (< 0.95 — simulation is behind real time)"
    fi

    # ── ROS2 topic list ───────────────────────────────────────────────────────
    TOPIC_LIST=$(sudo docker exec "$CONTAINER" bash -c "
        source /opt/ros/humble/setup.bash
        source /ros2_ws/install/setup.bash 2>/dev/null || true
        ros2 topic list 2>/dev/null
    " 2>/dev/null || echo "")

    for topic in /scan /camera/image_raw /imu /odom /clock; do
        if echo "$TOPIC_LIST" | grep -qx "$topic"; then
            pass "Topic exists: ${topic}"
        else
            fail "Topic missing: ${topic}"
        fi
    done

    # ── Sensor publication rates (message-count method) ───────────────────────
    info "Measuring sensor rates over ${MEASURE_SECS}s..."

    declare -A RATE_TARGETS=(["/scan"]="9.0" ["/camera/image_raw"]="9.0" ["/imu"]="20.0" ["/odom"]="10.0")
    declare -A GREP_FIELDS=(["/scan"]="ranges:" ["/camera/image_raw"]="height:" ["/imu"]="angular_velocity:" ["/odom"]="pose:")

    for topic in /scan /camera/image_raw /imu /odom; do
        field="${GREP_FIELDS[$topic]}"
        target="${RATE_TARGETS[$topic]}"

        count=$(sudo docker exec "$CONTAINER" bash -c "
            source /opt/ros/humble/setup.bash
            source /ros2_ws/install/setup.bash 2>/dev/null || true
            timeout $((MEASURE_SECS + 1)) ros2 topic echo --no-arr '${topic}' 2>/dev/null \
              | grep -c '${field}' || true
        " 2>/dev/null || echo "0")

        # Calculate rate
        if [[ "$count" -gt 0 ]]; then
            rate=$(awk "BEGIN{printf \"%.1f\", $count/$MEASURE_SECS}")
        else
            rate="0.0"
        fi

        if awk "BEGIN{exit !($rate >= $target)}"; then
            pass "$(printf '%-25s' ${topic}:) ${rate} Hz  (target ≥ ${target} Hz, count=${count})"
        else
            fail "$(printf '%-25s' ${topic}:) ${rate} Hz  (target ≥ ${target} Hz, count=${count})"
        fi
    done

    # ── Screenshot ────────────────────────────────────────────────────────────
    SCREEN_PATH="/tmp/${CONTAINER}_screen.png"
    if sudo docker exec "$CONTAINER" bash -c "DISPLAY=:99 scrot /tmp/screen_verify.png" &>/dev/null && \
       sudo docker cp "${CONTAINER}:/tmp/screen_verify.png" "$SCREEN_PATH" &>/dev/null; then
        info "Screenshot saved: ${SCREEN_PATH}"
    else
        info "Screenshot failed (non-critical)"
    fi

    echo ""
done

# ── Resource summary ──────────────────────────────────────────────────────────
echo -e "${CYAN}══════════════════════════════════════════${NC}"
echo -e "${CYAN} Resource Summary${NC}"
echo -e "${CYAN}══════════════════════════════════════════${NC}"

sudo docker stats --no-stream \
    --format "  {{.Name}}: CPU={{.CPUPerc}}  MEM={{.MemUsage}}" \
    $(sudo docker ps --filter "name=gz_" --format "{{.Names}}" | tr '\n' ' ') 2>/dev/null || true

echo ""
GPU_LINE=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
    --format=csv,noheader 2>/dev/null | head -1 || echo "N/A")
echo "  GPU: ${GPU_LINE}"
echo ""

# ── Final result ──────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo -e "${CYAN}══════════════════════════════════════════${NC}"
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}ALL CHECKS PASSED${NC}  (${PASS}/${TOTAL})"
else
    echo -e "  ${RED}${FAIL} CHECKS FAILED${NC}  (${PASS}/${TOTAL} passed)"
fi
echo -e "${CYAN}══════════════════════════════════════════${NC}"

[[ $FAIL -eq 0 ]]   # exit 0 on pass, 1 on any failure
