# GPU + Docker + ROS2 Gazebo Infrastructure

## Host VM Details

- Ubuntu 24.04 LTS
- NVIDIA Quadro RTX 8000 (48 GB VRAM)
- 8-core CPU, 7.7 GB RAM
- Secure Boot enabled
- Tailscale IP: `100.113.192.86` — always use this for URLs, not the public IP
- 4 GB swapfile at `/swapfile`, swappiness=1 (last resort only)

---

## 1. NVIDIA Driver

Ubuntu ships pre-compiled, Canonical-signed kernel modules for specific kernel versions.
**Do NOT use DKMS** when Secure Boot is enabled — DKMS-built modules are signed with a
local MOK key that is not enrolled, and will be rejected at load time.

### Install the pre-signed driver modules

```bash
# Find the right package for your running kernel
apt-cache search "linux-modules-nvidia.*$(uname -r)"

# Install — pick the highest driver version available for your kernel
sudo apt-get install -y linux-modules-nvidia-580-$(uname -r)

# Also install the userspace driver tools (pick matching version)
sudo apt-get install -y nvidia-driver-580
```

If `nvidia-driver-*` pulls in `nvidia-dkms-*` and builds a DKMS module, remove it
after install to prevent it from shadowing the Canonical-signed one:

```bash
sudo rm -f /lib/modules/$(uname -r)/updates/dkms/nvidia*.ko.zst
sudo depmod -a
```

### Load the modules

```bash
sudo modprobe nvidia
sudo modprobe nvidia-uvm
nvidia-smi   # should show GPU info
```

### On reboot

The modules load automatically via `/etc/modules-load.d/` or initramfs.
If they don't load after a kernel upgrade, re-run the apt install step above
for the new kernel version.

---

## 2. Swap

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Swappiness=1: only use swap as last resort (default 60 is too aggressive)
echo 'vm.swappiness=1' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl vm.swappiness=1
```

---

## 3. Docker

```bash
# Fix any malformed docker.list (Ubuntu 24.04 quirk)
# /etc/apt/sources.list.d/docker.list should contain:
# deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
sudo systemctl enable --now docker
```

---

## 4. NVIDIA Container Toolkit

```bash
# The toolkit is available in Ubuntu's repos on 24.04
sudo apt-get install -y nvidia-container-toolkit

# Configure Docker to use the NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Test GPU access inside a container
sudo docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi
```

---

## 5. Secure Boot Gotcha

If `modprobe nvidia` fails with **"Key was rejected by service"**:

1. Secure Boot is enabled and the module signing key is not enrolled.
2. Do NOT waste time trying to enroll via DKMS/`update-secureboot-policy` — it
   requires an interactive reboot with physical console access.
3. Use the Canonical-signed modules from Ubuntu repos instead (step 1 above).

Check Secure Boot state: `mokutil --sb-state`
Check machine keyring: `sudo keyctl list %:.platform`  (should NOT be empty if MOK enrolled)

---

## 6. ROS2 Gazebo Docker Setup

Uses **Gazebo Harmonic** (current LTS) + ROS2 Humble via the `ros_gz` bridge.
Gazebo Classic 11 is EOL (Sep 2025) and is not used.

The simulation runs **TurtleBot3 Burger** robots with full **NAV2 navigation stack**:
- Gazebo Harmonic physics + rendering
- Custom SDF robot model with 360° LiDAR
- ROS2 bridge for scan, odom, cmd_vel, tf, clock
- NAV2 (AMCL localization + DWB planner + costmaps)
- SLAM Toolbox for real-time mapping
- Random goal sender: robot autonomously navigates to random map points

See `docker-compose.yml` and `Dockerfile` in this directory.

### Build

```bash
cd ~/ros2-gazebo
docker compose build
```

### Run TurtleBot3 NAV2 demo (5 independent instances)

```bash
for i in $(seq 1 5); do
  HTTP=$((8079 + i)); VNC=$((5899 + i))
  sudo docker run -d \
    --name "gz_$i" --runtime=nvidia \
    -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e DISPLAY=:99 -e "ROS_DOMAIN_ID=$i" \
    -e VGL_DISPLAY=/dev/dri/card0 -e VGL_REFRESHRATE=60 \
    -e "__EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d/" \
    --device /dev/dri/card0:/dev/dri/card0 \
    --device /dev/dri/renderD128:/dev/dri/renderD128 \
    -p "${HTTP}:8080" -p "${VNC}:5900" \
    ros2-gazebo-gazebo:latest \
    ros2 launch tb3_sim tb3_nav2.launch.py
done
```

Access via Tailscale:
- http://100.113.192.86:8080/vnc.html?autoconnect=true&resize=scale  (instance 1)
- http://100.113.192.86:8081/vnc.html?autoconnect=true&resize=scale  (instance 2)
- http://100.113.192.86:8082/vnc.html?autoconnect=true&resize=scale  (instance 3)
- http://100.113.192.86:8083/vnc.html?autoconnect=true&resize=scale  (instance 4)
- http://100.113.192.86:8084/vnc.html?autoconnect=true&resize=scale  (instance 5)

### Take a screenshot from a running instance

```bash
sudo docker exec gz_1 bash -c "DISPLAY=:99 scrot /tmp/screen.png"
sudo docker cp gz_1:/tmp/screen.png /tmp/screen.png
# Then: Read /tmp/screen.png to view it
```

### Drop into a shell

```bash
docker compose run --rm gazebo bash
# ROS2 and display are already sourced/started by entrypoint.sh
```

### Add ROS2 packages

Place your package source in `src/`, then build inside the container:

```bash
docker compose run --rm gazebo bash -c "colcon build --symlink-install"
```

The built install space is ephemeral unless you add a named volume to docker-compose.yml.

### World files

- Use SDF 1.8+ format (not the old Gazebo Classic `model://sun` include style)
- Harmonic worlds must declare system plugins inline (Physics, SceneBroadcaster, UserCommands)
- See `worlds/tb3_world.sdf` for the TurtleBot3 navigation world

---

## Architecture

```
Browser (laptop)
    |  HTTP :8080
    v
noVNC (websockify)     <- inside container
    |  TCP :5900  (capped at 30fps via Xvnc -FrameRate 30)
    v
Xvnc (TigerVNC virtual display, 1920x1080, no WM = no title bars)
    |  X11 :99
    +-- Gazebo GUI (ign gazebo -g, on-demand: starts on VNC connect, stops on disconnect)
    +-- Gazebo Server (headless, EGL sensors, no GUI process at idle)
    +-- NAV2 stack    (AMCL + DWB planner + costmaps, headless)
    +-- Random goal sender (Python node)
```

### GUI version note

The Gazebo server uses `ign gazebo` (version 6.17.1, ign-gazebo-6).
The GUI **must** also use `ign gazebo -g`, NOT `gz sim -g` (which is version 8.x and
uses incompatible transport — will connect silently but render a black screen).
This is handled correctly in `entrypoint.sh`.


GPU is passed through via NVIDIA Container Toolkit (`runtime: nvidia`).
Rendering uses VirtualGL (`vglrun`) to redirect OpenGL calls to the NVIDIA GPU via EGL,
which provides vsync and caps the GUI render loop at 60fps.

### VirtualGL notes

- `VGL_DISPLAY=/dev/dri/card0` works. **Do NOT use `/dev/dri/renderD128`** — NVIDIA EGL
  rejects it with "Invalid EGL device" in this configuration.
- Both `/dev/dri/card0` and `/dev/dri/renderD128` must be passed to the container.
- The `libEGL warning: egl: failed to create dri2 screen` messages in logs are harmless
  noise from the Mesa DRI2 path; VirtualGL uses the NVIDIA EGL path successfully.

### Fullscreen notes

- Xvnc runs at 1920x1080. Without a window manager, X11 windows have no title bars
  or decorations — whatever size the app opens at is the full window.
- `config/gz_gui.config` sets `<width>1920</width><height>1080</height><x>0</x><y>0</y>`
  so Gazebo fills the entire virtual display.

### Performance notes (measured on Quadro RTX 8000, 8-core VM)

**Single instance (TurtleBot3 + NAV2, headless server + on-demand GUI):**

| Mode | CPU | RAM | Notes |
|---|---|---|---|
| Headless server (no VNC client) | ~85% | ~525 MiB | Server + NAV2 + sensors |
| With GUI (VNC client connected) | ~162% | ~900 MiB | Adds Ogre2 rendering via VirtualGL |

**Sensor publication rates (confirmed via message-count method, 15s window):**

| Topic | Rate | Target |
|---|---|---|
| `/scan` (LiDAR) | ~9.3 Hz | ≥10 Hz |
| `/camera/image_raw` | ~9.3 Hz | ≥10 Hz |
| `/imu` | ~44 Hz | — |
| `/odom` | ~16 Hz | — |

**Realtime factor:** 1.000 (physics at 50 Hz, steady)

**5 instances headless (empirically measured, TurtleBot3 + NAV2, no VNC clients):**

| Metric | Value | Notes |
|---|---|---|
| Total CPU | ~430% / 800% | ~85% per instance |
| Total RAM | ~2.6 GB | ~525 MiB per instance |
| VRAM | ~238 MiB/instance | 5 instances = ~1.2 GB |
| GPU utilization | ~21% | Sensor EGL rendering only |

**With 1 GUI connected (VNC client on instance 1):**

| Metric | Value |
|---|---|
| Total CPU | ~500% |
| Total RAM | ~3.0 GB |
| VRAM | ~1.2 GB |
| GPU utilization | ~28% |

**Efficiency gain vs always-on GUI baseline:**
- RAM: **~2.6 GB vs ~5.3 GB** (50% savings) when no VNC clients connected
- CPU: **~430% vs ~475%** when headless
- Practical capacity: **9 headless instances** before CPU saturation (vs 5-6 with GUI always on)

**Binding constraints on this VM (headless server mode):**
- **CPU**: Primary limit at ~85% each. 8 cores / 85% ≈ 9 instances before saturation.
- **RAM**: ~525 MiB each. 7.7 GB / 525 MiB ≈ 14 instances before OOM.
- **VRAM / GPU**: Not limiting. 48 GB VRAM / ~238 MiB ≈ 200+ instances possible by GPU alone.

**Practical recommendation**: **9 instances** headless on this 8-core / 7.7 GB VM.
Add GUI (VNC connect) to any instance on demand without affecting others.

**To scale further**: Add CPU cores (primary bottleneck now); RAM is no longer the limit.
