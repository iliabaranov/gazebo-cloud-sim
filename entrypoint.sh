#!/bin/bash
set -e

# ── GZ_PARTITION: isolate gz-transport discovery per container ────────────────
# Without this, gz-transport (ZMQ/multicast) can discover servers in *other*
# containers on the same Docker bridge, causing GUI clients to attach to the
# wrong simulation.
export GZ_PARTITION="sim_${ROS_DOMAIN_ID:-0}"

# ── TigerVNC virtual display ──────────────────────────────────────────────────
Xvnc :99 \
    -rfbport 5900 \
    -SecurityTypes None \
    -geometry 1920x1080 \
    -depth 24 \
    -FrameRate 30 \
    -ac &

# Wait for X11 socket
for i in $(seq 1 40); do
    [ -S /tmp/.X11-unix/X99 ] && break
    sleep 0.25
done
[ -S /tmp/.X11-unix/X99 ] || { echo "ERROR: X display :99 failed to start"; exit 1; }
sleep 0.5

# ── noVNC WebSocket proxy ─────────────────────────────────────────────────────
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

# ── VNC connection monitor ────────────────────────────────────────────────────
# Watches port 5900 for established client connections.
# Starts the Gazebo GUI (client-only, no server) when a VNC client connects,
# kills it when the last client disconnects.  The simulation server keeps
# running in both states.
vnc_gui_monitor() {
    local GUI_PID=""
    local LAST_LAUNCH=0
    local COOLDOWN=8   # seconds between restarts (avoids tight restart loops)

    echo "[vnc-monitor] started (GZ_PARTITION=${GZ_PARTITION})"

    while true; do
        sleep 2

        local now
        now=$(date +%s)

        # Count established TCP connections involving port 5900.
        # When a noVNC browser client is connected, websockify creates a
        # loopback TCP connection to Xvnc: 127.0.0.1:PORT → 127.0.0.1:5900
        # netstat (from net-tools) is used since iproute2/ss is not installed.
        local clients
        clients=$(netstat -tn 2>/dev/null \
            | awk '$6=="ESTABLISHED"{print $4,$5}' \
            | grep -c ':5900' || true)

        if [ "${clients:-0}" -gt 0 ]; then
            # ── VNC client present ──────────────────────────────────────────
            if { [ -z "$GUI_PID" ] || ! kill -0 "$GUI_PID" 2>/dev/null; } \
               && [ $((now - LAST_LAUNCH)) -ge $COOLDOWN ]; then
                echo "[vnc-monitor] client connected — launching Gazebo GUI"
                export XDG_RUNTIME_DIR=/tmp/runtime-root
                mkdir -p /tmp/runtime-root && chmod 700 /tmp/runtime-root
                DISPLAY=:99 vglrun ign gazebo -g \
                    --gui-config /ros2_ws/config/gz_gui.config \
                    2>/tmp/gz_gui.log &
                GUI_PID=$!
                LAST_LAUNCH=$now
            fi
        else
            # ── No VNC clients ──────────────────────────────────────────────
            if [ -n "$GUI_PID" ] && kill -0 "$GUI_PID" 2>/dev/null; then
                echo "[vnc-monitor] last client disconnected — stopping Gazebo GUI"
                kill "$GUI_PID" 2>/dev/null
                wait "$GUI_PID" 2>/dev/null || true
                GUI_PID=""
            fi
        fi
    done
}
vnc_gui_monitor &

# ── Per-instance persistent data volume ───────────────────────────────────────
# The orchestrator mounts a named Docker volume at /instance_data.
# On first start the volume is empty, so we seed it from the image defaults.
# On every start we symlink the installed package share dirs into the volume so
# that ROS launch files transparently read (and persist) the user's files.
# Works with or without the orchestrator: if /instance_data is just an empty
# directory (no named volume), data is ephemeral but behaviour is correct.
PKG_SHARE=/ros2_ws/install/tb3_sim/share/tb3_sim
mkdir -p /instance_data

if [ ! -f /instance_data/.initialized ]; then
    echo "[vol-init] Seeding persistent volume from image defaults..."
    for _d in worlds urdf params maps; do
        cp -r "${PKG_SHARE}/${_d}" /instance_data/
    done
    mkdir -p /instance_data/config
    cp -r /ros2_ws/config/. /instance_data/config/
    touch /instance_data/.initialized
    echo "[vol-init] Done."
fi

# Redirect installed package dirs → persistent volume via symlinks.
# Runs on every container start (symlinks live in the ephemeral writable layer).
for _d in worlds urdf params maps; do
    rm -rf "${PKG_SHARE}/${_d}"
    ln -s "/instance_data/${_d}" "${PKG_SHARE}/${_d}"
done
rm -rf /ros2_ws/config
ln -s /instance_data/config /ros2_ws/config

# ── ROS 2 environment ─────────────────────────────────────────────────────────
source /opt/ros/humble/setup.bash

if [ -f /ros2_ws/install/setup.bash ]; then
    source /ros2_ws/install/setup.bash
fi

echo "================================================"
echo "  noVNC  : http://localhost:8080/vnc.html"
echo "  GZ_PARTITION: ${GZ_PARTITION}"
echo "  Gazebo GUI starts on first VNC client connect"
echo "================================================"

exec "$@"
