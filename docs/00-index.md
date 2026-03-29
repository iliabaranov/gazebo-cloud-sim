# ROS2 Gazebo Simulation — Complete Codebase Reference

This `docs/` folder contains the full source of every file in the project,
embedded in markdown for easy transport to a new system.

---

## Document Map

| File | Contents |
|---|---|
| **[01-infrastructure.md](01-infrastructure.md)** | `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `config/gz_gui.config` |
| **[02-ros2-package.md](02-ros2-package.md)** | `src/tb3_sim/` — launch, worlds, URDF, NAV2 params, maps, goal sender |
| **[03-scripts.md](03-scripts.md)** | `scripts/` — setup-host, run, stop, verify, capacity-test |
| **[04-orchestrator.md](04-orchestrator.md)** | `orchestrator/` — `gz-sim` CLI, `health-monitor`, `SimulatorManager` library |

---

## Reconstruct From Scratch

### 1 — Prerequisites

```bash
# Ubuntu 22.04 or 24.04, NVIDIA GPU required
sudo bash scripts/setup-host.sh   # installs NVIDIA driver, Docker, swap
```

### 2 — Directory skeleton

```bash
mkdir -p ros2-gazebo/{config,scripts,docs}
mkdir -p ros2-gazebo/src/tb3_sim/{launch,worlds,urdf,maps,params,tb3_sim,resource}
mkdir -p ros2-gazebo/orchestrator/gz_sim
cd ros2-gazebo
```

### 3 — Recreate each file

Work through the docs in order:

```
01-infrastructure.md  →  Dockerfile, docker-compose.yml, entrypoint.sh, config/gz_gui.config
02-ros2-package.md    →  all src/tb3_sim/** files
03-scripts.md         →  scripts/*.sh
04-orchestrator.md    →  orchestrator/**
```

Copy the binary map file from the source system (cannot be embedded in markdown):

```bash
scp user@source:~/ros2-gazebo/src/tb3_sim/maps/tb3_world.pgm \
    src/tb3_sim/maps/tb3_world.pgm
```

Create the empty ament resource marker:

```bash
touch src/tb3_sim/resource/tb3_sim
```

### 4 — Permissions

```bash
chmod +x entrypoint.sh scripts/*.sh
chmod +x orchestrator/gz-sim orchestrator/health-monitor orchestrator/install.sh
```

### 5 — Build and run

```bash
sudo docker compose build          # ~10 min first time

sudo bash orchestrator/install.sh  # installs gz-sim CLI

gz-sim start --n 5                 # start 5 instances
gz-sim status --rtf                # verify all healthy

# Open in browser (replace IP with your host):
# http://<host-ip>:8080/vnc.html?autoconnect=true&resize=scale
```

### 6 — Health monitor (optional background daemon)

```bash
nohup gz-sim-health >> /tmp/gz-health.log 2>&1 &
echo $! > /tmp/gz-health.pid
tail -f /tmp/gz-health.log
```

---

## Key Design Decisions

### Gazebo version mismatch
The server runs as `ign gazebo` (ign-gazebo-6, v6.17.1). The GUI **must** use
`ign gazebo -g` — not `gz sim -g` (v8.x), which connects silently but renders
a black screen due to incompatible gz-transport. `entrypoint.sh` handles this.

### On-demand GUI
The Gazebo 3D view is started only when a browser connects to noVNC, and killed
when the last browser disconnects. The simulation server keeps running.
Savings: ~375 MiB RAM and ~77% CPU per idle instance.

### Persistent volumes
Each instance `gz_N` gets a named Docker volume `gz_data_N` mounted at
`/instance_data`. On first start, `entrypoint.sh` seeds it from image defaults.
On every start, installed share dirs are symlinked into the volume so the launch
file reads the persistent (user-modifiable) files transparently.

Files that persist per instance:
- `worlds/`  — SDF world files
- `urdf/`    — robot URDF
- `params/`  — NAV2 configuration
- `maps/`    — pre-built occupancy maps
- `config/`  — Gazebo GUI layout

Reset to defaults: `gz-sim reset <id>`

### Future API layer
`orchestrator/gz_sim/manager.py` contains `SimulatorManager` — the same class
the CLI calls. A FastAPI server imports it directly; no logic is duplicated.
See the "Future API Extension" section in `04-orchestrator.md`.

---

## Measured Performance (Quadro RTX 8000, 8-core, 7.7 GB RAM)

| Metric | Value |
|---|---|
| Realtime factor | 1.000 (stable) |
| LiDAR `/scan` | ~9.3 Hz |
| Camera `/camera/image_raw` | ~9.3 Hz |
| CPU / instance (headless) | ~85% |
| RAM / instance (headless) | ~525 MiB |
| RAM / instance (GUI active) | ~900 MiB |
| Max instances before CPU saturation | ~9 headless |
