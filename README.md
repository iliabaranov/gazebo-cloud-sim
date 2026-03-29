# ROS2 + Gazebo Harmonic — TurtleBot3 NAV2 Multi-Instance Simulator

Runs multiple independent TurtleBot3 Burger simulations in Docker containers, each with:
- **Gazebo Harmonic** physics + GPU-accelerated sensor rendering (EGL headless)
- **NAV2** full navigation stack (AMCL localisation, DWB planner, costmaps)
- **Camera** (640×480, ~10 Hz) + **LiDAR** (360°, ~10 Hz) + IMU + Odometry
- **Browser-based VNC** via noVNC (no client software needed)
- **On-demand GUI**: Gazebo 3D view starts when a browser connects, stops when it disconnects

---

## Requirements

| Component | Minimum | Notes |
|---|---|---|
| OS | Ubuntu 22.04 or 24.04 | Host, not container |
| CPU | 4 cores | Each headless instance uses ~85% of one core |
| RAM | 4 GB | ~525 MiB per instance headless; ~900 MiB with GUI |
| GPU | NVIDIA (any modern) | Required — used for sensor rendering and GUI |
| VRAM | 1 GB | ~238 MiB per instance; not a practical limit |
| Disk | 20 GB free | Docker image is ~8 GB |
| Docker | 24+ | With NVIDIA Container Toolkit |

> **Secure Boot**: If enabled, use the Canonical-signed NVIDIA driver packages
> (`linux-modules-nvidia-*`) rather than DKMS. See `scripts/setup-host.sh` for details.

---

## Quick Start

```bash
# 1. Set up host prerequisites (NVIDIA driver, Docker, NVIDIA Container Toolkit, swap)
#    Skip steps you've already done — the script checks before acting.
sudo bash scripts/setup-host.sh

# 2. Build the Docker image (~10 min first time)
sudo docker compose build

# 3. Start 5 simulation instances
bash scripts/run.sh 5

# 4. Open your browser
#    Instance 1: http://<host-ip>:8080/vnc.html?autoconnect=true&resize=scale
#    Instance 2: http://<host-ip>:8081/vnc.html?autoconnect=true&resize=scale
#    ...

# 5. Verify sensors and performance (wait ~40s for NAV2 to initialise first)
bash scripts/verify.sh

# 6. Stop all instances
bash scripts/stop.sh
```

---

## Orchestrator — `gz-sim` CLI

The orchestrator manages container lifecycle, health monitoring, and persistent volumes. Install it once after building the image:

```bash
sudo bash orchestrator/install.sh   # installs gz-sim and gz-sim-health to /usr/local/bin
```

### Common commands

```bash
# Show all running instances (CPU, RAM, URLs)
gz-sim status

# Show status + measure realtime factor (~6s, runs in parallel)
gz-sim status --rtf

# Start 3 new instances (uses lowest available IDs)
gz-sim start --n 3

# Stop one instance (volume is preserved)
gz-sim stop 2

# Stop all instances
gz-sim stop all

# Scale to exactly N running instances (starts or stops as needed)
gz-sim scale 5

# Restart one instance (keeps its persistent volume)
gz-sim restart 1

# Wipe an instance's volume and restart from image defaults
gz-sim reset 1

# Stream logs from an instance
gz-sim logs 1

# Open a bash shell inside an instance (ROS2 env pre-sourced)
gz-sim shell 1

# List all persistent data volumes
gz-sim volumes
```

### Health monitor

Polls the realtime factor of every running instance every 30s and automatically restarts any that fall below RTF 0.80 for 3 consecutive rounds:

```bash
# Run in the background
nohup gz-sim-health >> /tmp/gz-health.log 2>&1 &
echo $! > /tmp/gz-health.pid

# Follow logs
tail -f /tmp/gz-health.log

# Stop
kill $(cat /tmp/gz-health.pid)
```

### Connecting to instances

Each instance `N` (1-based) exposes:

| Service | Host port | How to connect |
|---|---|---|
| noVNC (browser) | `8079 + N` → 8080, 8081 … | `http://<host>:8080/vnc.html?autoconnect=true&resize=scale` |
| Raw VNC | `5899 + N` → 5900, 5901 … | Any VNC client |
| Foxglove / rosbridge | `8089 + N` → 8090, 8091 … | Foxglove Studio → **ROS Bridge WebSocket** → `ws://<host>:8090` |

Instances are isolated via `ROS_DOMAIN_ID=N` and `GZ_PARTITION=sim_N`.

---

## Architecture

```
Browser
  │  HTTP :808x
  ▼
noVNC / websockify          ← inside container
  │  TCP :590x
  ▼
Xvnc (TigerVNC :99, 1920×1080)
  ├── Gazebo GUI  (ign gazebo -g, starts on VNC connect / stops on disconnect)
  ├── Gazebo Server  (headless EGL, physics 50 Hz)
  ├── NAV2  (AMCL + DWB planner + costmaps)
  └── random_goal_sender  (continuous autonomous navigation)
```

GPU rendering uses **VirtualGL** (`vglrun`) which routes OpenGL calls to the NVIDIA
GPU via EGL and composites the result back to the Xvnc virtual display.

### Gazebo version note

The server runs as `ign gazebo` (ign-gazebo-6, v6.17.1).
The GUI **must** use `ign gazebo -g` — using `gz sim -g` (v8.x) connects silently
but renders a black screen due to incompatible transport. `entrypoint.sh` handles this.

---

## Measured Performance (Quadro RTX 8000, 8-core, 7.7 GB RAM)

| Metric | Value |
|---|---|
| Realtime factor | **1.000** (stable) |
| LiDAR `/scan` | **~9.3 Hz** |
| Camera `/camera/image_raw` | **~9.3 Hz** |
| IMU `/imu` | ~44 Hz |
| CPU / instance (headless) | ~85% |
| RAM / instance (headless) | ~525 MiB |
| RAM / instance (GUI active) | ~900 MiB |
| VRAM / instance | ~238 MiB |
| **Max instances (CPU limit)** | **~9 headless** |

---

## Files

```
gazebo-cloud-sim/
├── Dockerfile                  ← container image definition
├── docker-compose.yml          ← single-instance compose config
├── entrypoint.sh               ← container startup (VNC, Gazebo, ROS2)
├── config/
│   └── gz_gui.config           ← Gazebo GUI layout (1920×1080 fullscreen)
├── orchestrator/
│   ├── gz-sim                  ← CLI entry point (installed to PATH)
│   ├── health-monitor          ← RTF daemon (installed as gz-sim-health)
│   ├── install.sh              ← installs CLI + deps, symlinks to /usr/local/bin
│   ├── requirements.txt        ← Python deps (docker, click, rich)
│   └── gz_sim/
│       ├── config.py           ← ports, limits, thresholds (env-overridable)
│       ├── manager.py          ← SimulatorManager — all Docker logic
│       └── models.py           ← Instance dataclass
├── scripts/
│   ├── setup-host.sh           ← install NVIDIA driver, Docker, NVIDIA Container Toolkit
│   ├── run.sh                  ← start N containers (simple, no orchestrator)
│   ├── stop.sh                 ← stop and remove all gz_ containers
│   ├── verify.sh               ← check sensors, RTF, take screenshot
│   └── capacity-test.sh        ← ramp up instances, measure limits
├── src/
│   └── tb3_sim/                ← ROS2 package (built into image at build time)
│       ├── launch/tb3_nav2.launch.py
│       ├── worlds/tb3_world.sdf
│       ├── urdf/turtlebot3_burger.urdf
│       ├── maps/tb3_world.{pgm,yaml}
│       ├── params/nav2_params.yaml
│       └── tb3_sim/random_goal_sender.py
└── docs/                       ← full codebase in markdown (for system transport)
    ├── 00-index.md
    ├── 01-infrastructure.md
    ├── 02-ros2-package.md
    ├── 03-scripts.md
    └── 04-orchestrator.md
```

---

## Troubleshooting

**Black screen in browser**
- Wait 30s after connecting — the GUI needs time to load the scene.
- Check `docker exec gz_1 cat /tmp/gz_gui.log` for errors.
- Confirm the GUI is running: `docker exec gz_1 ps aux | grep 'ign gazebo -g'`

**`nvidia-smi` fails inside container**
- Ensure `--runtime=nvidia` is passed (or `runtime: nvidia` in compose).
- Check host: `nvidia-smi` should work on the host before trying in containers.

**Simulation running slower than real time (RTF < 0.95)**
- Too many instances for available CPU. Try reducing count in `run.sh`.
- Run `bash scripts/verify.sh` to check RTF across all instances.

**`docker: Error response from daemon: Unknown runtime specified nvidia`**
- NVIDIA Container Toolkit not configured: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`

**VGL_DISPLAY errors / black rendering**
- Use `/dev/dri/card0`, not `/dev/dri/renderD128`. The latter is rejected by NVIDIA EGL.
- Both devices must be passed to the container (see `run.sh`).

**Sensor rates below 10 Hz**
- Check the simulation RTF first — if RTF < 1.0, physics is behind and sensors slow down.
- Camera uses `ros_gz_image/image_bridge` for efficient transport; check it's running:
  `docker exec gz_1 ros2 node list | grep image_bridge`
