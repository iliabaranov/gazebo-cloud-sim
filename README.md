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

## Port Layout

Each instance `N` (1-based) uses:

| Service | Port |
|---|---|
| noVNC (browser) | `8079 + N` → 8080, 8081, 8082 … |
| Raw VNC | `5899 + N` → 5900, 5901, 5902 … |

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
ros2-gazebo/
├── README.md                   ← you are here
├── Dockerfile                  ← container image definition
├── docker-compose.yml          ← single-instance compose config
├── entrypoint.sh               ← container startup (VNC, Gazebo, ROS2)
├── config/
│   └── gz_gui.config           ← Gazebo GUI layout (1920×1080 fullscreen)
├── scripts/
│   ├── setup-host.sh           ← install NVIDIA driver, Docker, NVIDIA Container Toolkit
│   ├── run.sh                  ← start N containers
│   ├── stop.sh                 ← stop and remove all gz_ containers
│   ├── verify.sh               ← check sensors, RTF, take screenshot
│   └── capacity-test.sh        ← ramp up instances, measure limits
└── src/
    └── tb3_sim/                ← ROS2 package (built into image at build time)
        ├── launch/tb3_nav2.launch.py
        ├── worlds/tb3_world.sdf
        ├── urdf/turtlebot3_burger.urdf
        ├── maps/tb3_world.{pgm,yaml}
        ├── params/nav2_params.yaml
        └── tb3_sim/random_goal_sender.py
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
