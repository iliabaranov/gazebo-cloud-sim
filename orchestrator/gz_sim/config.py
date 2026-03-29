"""
Central configuration for the gz-sim orchestrator.
All values can be overridden with environment variables.
"""
import os

# ── Docker image ───────────────────────────────────────────────────────────────
IMAGE = os.environ.get("GZ_IMAGE", "ros2-gazebo-gazebo:latest")

# ── Container / volume naming ─────────────────────────────────────────────────
CONTAINER_PREFIX = "gz_"       # containers: gz_1, gz_2, ...
VOLUME_PREFIX    = "gz_data_"  # volumes:    gz_data_1, gz_data_2, ...

# ── Port allocation  (instance N → base + N) ──────────────────────────────────
HTTP_BASE_PORT      = 8079   # noVNC:       gz_1 → 8080,  gz_2 → 8081, ...  (8080-8088)
VNC_BASE_PORT       = 5899   # raw VNC:     gz_1 → 5900,  gz_2 → 5901, ...
FOXGLOVE_BASE_PORT  = 8089   # rosbridge:   gz_1 → 8090,  gz_2 → 8091, ...  (8090-8098)

# ── Capacity ──────────────────────────────────────────────────────────────────
# CPU-limited to ~9 on 8-core VM. Override with GZ_MAX_INSTANCES.
MAX_INSTANCES = int(os.environ.get("GZ_MAX_INSTANCES", "9"))

# ── Docker device passthrough ─────────────────────────────────────────────────
GPU_DEVICES = [
    "/dev/dri/card0:/dev/dri/card0:rwm",
    "/dev/dri/renderD128:/dev/dri/renderD128:rwm",
]

# ── Container environment ─────────────────────────────────────────────────────
CONTAINER_ENV = {
    "NVIDIA_VISIBLE_DEVICES":        "all",
    "NVIDIA_DRIVER_CAPABILITIES":    "all",
    "DISPLAY":                       ":99",
    "VGL_DISPLAY":                   "/dev/dri/card0",
    "VGL_REFRESHRATE":               "60",
    "__EGL_VENDOR_LIBRARY_DIRS":     "/usr/share/glvnd/egl_vendor.d/",
}

# ── Health monitor ────────────────────────────────────────────────────────────
# Below this RTF → unhealthy. Override with GZ_RTF_THRESHOLD.
RTF_THRESHOLD           = float(os.environ.get("GZ_RTF_THRESHOLD",    "0.80"))
# Seconds to collect /stats samples per measurement.
RTF_MEASURE_SECS        = int(os.environ.get("GZ_RTF_MEASURE_SECS",   "6"))
# Seconds between health-check rounds.
RTF_POLL_INTERVAL       = int(os.environ.get("GZ_RTF_POLL_INTERVAL",  "30"))
# Consecutive unhealthy rounds before restart.
RTF_FAILURES_TO_RESTART = int(os.environ.get("GZ_RTF_FAILURES",       "3"))
# Seconds to wait after stop before restarting (let ports free up).
RESTART_DELAY_SECS      = int(os.environ.get("GZ_RESTART_DELAY",      "3"))
