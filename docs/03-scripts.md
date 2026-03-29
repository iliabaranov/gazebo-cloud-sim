# Scripts: Setup, Run, Stop, Verify, Capacity Test

These are the host-side shell scripts for setting up the machine, managing container lifecycle, and verifying the simulation. They live in `scripts/` at the project root.

---

## `scripts/setup-host.sh`

One-time host preparation: installs the NVIDIA driver (Secure Boot-safe, Canonical-signed), Docker CE, NVIDIA Container Toolkit, and a 4 GB swapfile. Safe to re-run — each step checks whether it is already done.

```bash
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
```

---

## `scripts/run.sh`

Start N TurtleBot3 NAV2 simulation instances. Allocates ports sequentially (noVNC on `8080+N`, raw VNC on `5900+N`), skips already-running containers, and prints access URLs using the Tailscale IP when available.

```bash
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
```

---

## `scripts/stop.sh`

Stop and remove all `gz_*` containers (or a specific one by name). Named volumes are not touched, so persistent data survives.

```bash
#!/usr/bin/env bash
# stop.sh — Stop and remove all gz_ simulation containers.
#
# Usage:
#   bash scripts/stop.sh          # stop all gz_* containers
#   bash scripts/stop.sh gz_1     # stop a specific container

set -euo pipefail

if [[ $# -gt 0 ]]; then
    CONTAINERS=("$@")
else
    mapfile -t CONTAINERS < <(sudo docker ps -a --filter "name=gz_" --format "{{.Names}}")
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo "No gz_ containers found."
    exit 0
fi

echo "Stopping ${#CONTAINERS[@]} container(s): ${CONTAINERS[*]}"

for name in "${CONTAINERS[@]}"; do
    sudo docker stop "$name" &>/dev/null && echo "  stopped: $name" || true
    sudo docker rm   "$name" &>/dev/null && echo "  removed: $name" || true
done

echo "Done."
```

---

## `scripts/verify.sh`

Deep health check for all running `gz_*` containers (or a single named one). For each instance it checks: Gazebo server process, realtime factor via `/stats`, ROS2 topic existence (`/scan`, `/camera/image_raw`, `/imu`, `/odom`, `/clock`), sensor publication rates over a 15-second window, and saves a screenshot to `/tmp/`.

```bash
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
```

---

## `scripts/capacity-test.sh`

Ramp up simulation instances one at a time, measuring CPU, RAM, GPU utilisation, and realtime factor at each step. Stops automatically when available RAM drops below 500 MiB or RTF falls below 0.80. All test containers (`gz_cap_N`) are cleaned up on exit.

```bash
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
```

---

## Reconstruction

To reconstruct the `scripts/` directory from scratch:

1. Create the directory at the project root:
   ```bash
   mkdir -p scripts/
   ```

2. Place each file at the correct path:
   - `scripts/setup-host.sh`
   - `scripts/run.sh`
   - `scripts/stop.sh`
   - `scripts/verify.sh`
   - `scripts/capacity-test.sh`

3. Make all scripts executable:
   ```bash
   chmod +x scripts/*.sh
   ```

4. Proceed to `04-orchestrator.md` for the Python orchestrator layer.
