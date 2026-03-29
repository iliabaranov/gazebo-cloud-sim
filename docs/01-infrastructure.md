# Infrastructure: Dockerfile, Compose, Entrypoint, GUI Config

This document is a codebase transport record for the `ros2-gazebo` project's infrastructure layer. It contains the full, verbatim content of every infrastructure file needed to run the ROS2 + Gazebo Harmonic simulation stack inside Docker with GPU passthrough and browser-accessible noVNC display.

**How to use this document to reconstruct the files:**

Read the "Reconstruction" section at the bottom before starting. Each section below shows the file path relative to the project root, a one-line description, and the complete file content. Copy each block exactly as shown — whitespace and line endings matter, especially for the shell script.

---

## `Dockerfile`

Builds the simulation image: installs Gazebo Harmonic, ROS2 Humble bridge, NAV2, TigerVNC, noVNC, VirtualGL, and the `tb3_sim` ROS2 package.

```dockerfile
FROM osrf/ros:humble-desktop

ENV DEBIAN_FRONTEND=noninteractive

# Add OSRF repo for Gazebo Harmonic
RUN apt-get update && apt-get install -y curl && \
    curl -sSL https://packages.osrfoundation.org/gazebo.gpg \
        -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] \
        http://packages.osrfoundation.org/gazebo/ubuntu-stable jammy main" \
        > /etc/apt/sources.list.d/gazebo-stable.list

# Gazebo Harmonic + ROS2 bridge + NAV2 + display stack
RUN apt-get update && apt-get install -y \
    gz-harmonic \
    ros-humble-ros-gz \
    ros-humble-xacro \
    ros-humble-joint-state-publisher \
    ros-humble-navigation2 \
    ros-humble-nav2-bringup \
    ros-humble-slam-toolbox \
    ros-humble-robot-state-publisher \
    ros-humble-turtlebot3 \
    ros-humble-turtlebot3-msgs \
    ros-humble-rosbridge-suite \
    tigervnc-standalone-server \
    novnc \
    websockify \
    mesa-utils \
    libegl1-mesa \
    libglu1-mesa \
    python3-colcon-common-extensions \
    scrot \
    && rm -rf /var/lib/apt/lists/*

# Install VirtualGL — redirects OpenGL calls to NVIDIA GPU via EGL
ARG VGL_VERSION=3.1.4
RUN curl -fsSL "https://github.com/VirtualGL/virtualgl/releases/download/${VGL_VERSION}/virtualgl_${VGL_VERSION}_amd64.deb" \
        -o /tmp/vgl.deb && \
    apt-get install -y /tmp/vgl.deb && \
    rm /tmp/vgl.deb

# Environment
ENV DISPLAY=:99
ENV ROS_DOMAIN_ID=0
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all
# VirtualGL: use NVIDIA GPU via EGL render node (card0 works; renderD128 does NOT)
ENV VGL_DISPLAY=/dev/dri/card0
ENV VGL_REFRESHRATE=60
# Tell GLVND/EGL to use NVIDIA implementation
ENV __EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d/
# TurtleBot3 model
ENV TURTLEBOT3_MODEL=burger

# Copy config and entrypoint
COPY entrypoint.sh /entrypoint.sh
COPY config/ /ros2_ws/config/
RUN chmod +x /entrypoint.sh

# Copy and build ROS2 workspace (tb3_sim package)
COPY src/ /ros2_ws/src/
RUN /bin/bash -c "source /opt/ros/humble/setup.bash && \
    cd /ros2_ws && \
    colcon build --packages-select tb3_sim \
    && rm -rf build log"

WORKDIR /ros2_ws

ENTRYPOINT ["/entrypoint.sh"]
# Default: TurtleBot3 NAV2 demo
CMD ["ros2", "launch", "tb3_sim", "tb3_nav2.launch.py"]
```

---

## `docker-compose.yml`

Defines the `gazebo` service with NVIDIA runtime, GPU device passthrough, noVNC port mapping, and bind mounts for worlds, source, and config.

```yaml
services:

  gazebo:
    build: .
    container_name: ros2_gazebo
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=all
      - DISPLAY=:99
      - ROS_DOMAIN_ID=0
      - VGL_DISPLAY=/dev/dri/card0
      - VGL_REFRESHRATE=60
      - __EGL_VENDOR_LIBRARY_DIRS=/usr/share/glvnd/egl_vendor.d/
    devices:
      - /dev/dri/card0:/dev/dri/card0
      - /dev/dri/renderD128:/dev/dri/renderD128
    ports:
      - "8080:8080"   # noVNC browser interface  -> http://<host-ip>:8080/vnc.html
      - "5900:5900"   # Raw VNC (optional, for VNC clients)
    volumes:
      - ./worlds:/ros2_ws/worlds:ro
      - ./src:/ros2_ws/src
      - ./config:/ros2_ws/config:ro
    stdin_open: true
    tty: true
    # Override CMD to load a specific world:
    #   docker compose run gazebo vglrun ros2 launch ros_gz_sim gz_sim.launch.py \
    #     gz_args:="-r --gui-config /ros2_ws/config/gz_gui.config /ros2_ws/worlds/demo.sdf"
```

---

## `entrypoint.sh`

Container entrypoint: starts TigerVNC and noVNC, runs an on-demand Gazebo GUI monitor that launches the GUI when a VNC client connects and kills it on disconnect, seeds and symlinks the persistent instance data volume, sources the ROS2 workspace, then execs the CMD.

```bash
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
```

---

## `config/gz_gui.config`

Gazebo GUI layout configuration: sets the window to fill the 1920x1080 virtual display, configures the ogre2 3D scene, and positions all standard GUI plugins (world control, stats, transform tools, inspector, entity tree).

```xml
<?xml version="1.0"?>

<!-- Quick start dialog -->
<dialog name="quick_start" show_again="false"/>

<!-- Window — sized to fill the 1920x1080 Xvnc display.
     No WM in container means no title bar, so this is truly fullscreen. -->
<window>
  <width>1920</width>
  <height>1080</height>
  <x>0</x>
  <y>0</y>
  <style
    material_theme="Light"
    material_primary="DeepOrange"
    material_accent="LightBlue"
    toolbar_color_light="#f3f3f3"
    toolbar_text_color_light="#111111"
    toolbar_color_dark="#414141"
    toolbar_text_color_dark="#f3f3f3"
    plugin_toolbar_color_light="#bbdefb"
    plugin_toolbar_text_color_light="#111111"
    plugin_toolbar_color_dark="#607d8b"
    plugin_toolbar_text_color_dark="#eeeeee"
  />
  <menus>
    <drawer default="false">
    </drawer>
  </menus>
  <dialog_on_exit>false</dialog_on_exit>
</window>

<!-- GUI plugins -->

<!-- 3D scene: ogre2 — full quality now that rendering is on the NVIDIA GPU via VirtualGL -->
<plugin filename="MinimalScene" name="3D View">
  <ignition-gui>
    <title>3D View</title>
    <property type="bool" key="showTitleBar">false</property>
    <property type="string" key="state">docked</property>
  </ignition-gui>

  <engine>ogre2</engine>
  <scene>scene</scene>
  <ambient_light>0.4 0.4 0.4</ambient_light>
  <background_color>0.8 0.8 0.8</background_color>
  <camera_pose>-6 0 6 0 0.5 0</camera_pose>
</plugin>

<!-- Plugins that add functionality to the scene -->
<plugin filename="EntityContextMenuPlugin" name="Entity context menu">
  <ignition-gui>
    <property key="state" type="string">floating</property>
    <property key="width" type="double">5</property>
    <property key="height" type="double">5</property>
    <property key="showTitleBar" type="bool">false</property>
  </ignition-gui>
</plugin>
<plugin filename="GzSceneManager" name="Scene Manager">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="width" type="double">5</property>
    <property key="height" type="double">5</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
  </ignition-gui>
</plugin>
<plugin filename="InteractiveViewControl" name="Interactive view control">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="width" type="double">5</property>
    <property key="height" type="double">5</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
  </ignition-gui>
</plugin>
<plugin filename="CameraTracking" name="Camera Tracking">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="width" type="double">5</property>
    <property key="height" type="double">5</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
  </ignition-gui>
</plugin>
<plugin filename="MarkerManager" name="Marker manager">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="width" type="double">5</property>
    <property key="height" type="double">5</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
  </ignition-gui>
</plugin>
<plugin filename="SelectEntities" name="Select Entities">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="width" type="double">5</property>
    <property key="height" type="double">5</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
  </ignition-gui>
</plugin>
<plugin filename="Spawn" name="Spawn Entities">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="width" type="double">5</property>
    <property key="height" type="double">5</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
  </ignition-gui>
</plugin>
<plugin filename="VisualizationCapabilities" name="Visualization Capabilities">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="width" type="double">5</property>
    <property key="height" type="double">5</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
  </ignition-gui>
</plugin>

<!-- World control -->
<plugin filename="WorldControl" name="World control">
  <ignition-gui>
    <title>World control</title>
    <property type="bool" key="showTitleBar">false</property>
    <property type="bool" key="resizable">false</property>
    <property type="double" key="height">72</property>
    <property type="double" key="width">121</property>
    <property type="double" key="z">1</property>
    <property type="string" key="state">floating</property>
    <anchors target="3D View">
      <line own="left" target="left"/>
      <line own="bottom" target="bottom"/>
    </anchors>
  </ignition-gui>
  <play_pause>true</play_pause>
  <step>true</step>
  <start_paused>true</start_paused>
  <use_event>true</use_event>
</plugin>

<!-- World statistics -->
<plugin filename="WorldStats" name="World stats">
  <ignition-gui>
    <title>World stats</title>
    <property type="bool" key="showTitleBar">false</property>
    <property type="bool" key="resizable">false</property>
    <property type="double" key="height">110</property>
    <property type="double" key="width">290</property>
    <property type="double" key="z">1</property>
    <property type="string" key="state">floating</property>
    <anchors target="3D View">
      <line own="right" target="right"/>
      <line own="bottom" target="bottom"/>
    </anchors>
  </ignition-gui>
  <sim_time>true</sim_time>
  <real_time>true</real_time>
  <real_time_factor>true</real_time_factor>
  <iterations>true</iterations>
</plugin>

<!-- Insert simple shapes -->
<plugin filename="Shapes" name="Shapes">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="x" type="double">0</property>
    <property key="y" type="double">0</property>
    <property key="width" type="double">250</property>
    <property key="height" type="double">50</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
    <property key="cardBackground" type="string">#666666</property>
  </ignition-gui>
</plugin>

<!-- Insert lights -->
<plugin filename="Lights" name="Lights">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="x" type="double">250</property>
    <property key="y" type="double">0</property>
    <property key="width" type="double">150</property>
    <property key="height" type="double">50</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
    <property key="cardBackground" type="string">#666666</property>
  </ignition-gui>
</plugin>

<!-- Translate / rotate -->
<plugin filename="TransformControl" name="Transform control">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="x" type="double">0</property>
    <property key="y" type="double">50</property>
    <property key="width" type="double">250</property>
    <property key="height" type="double">50</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
    <property key="cardBackground" type="string">#777777</property>
  </ignition-gui>
  <legacy>false</legacy>
</plugin>

<!-- Screenshot -->
<plugin filename="Screenshot" name="Screenshot">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="x" type="double">250</property>
    <property key="y" type="double">50</property>
    <property key="width" type="double">50</property>
    <property key="height" type="double">50</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
    <property key="cardBackground" type="string">#777777</property>
  </ignition-gui>
</plugin>

<!-- Copy/Paste -->
<plugin filename="CopyPaste" name="CopyPaste">
  <ignition-gui>
    <property key="resizable" type="bool">false</property>
    <property key="x" type="double">300</property>
    <property key="y" type="double">50</property>
    <property key="width" type="double">100</property>
    <property key="height" type="double">50</property>
    <property key="state" type="string">floating</property>
    <property key="showTitleBar" type="bool">false</property>
    <property key="cardBackground" type="string">#777777</property>
  </ignition-gui>
</plugin>

<!-- Inspector -->
<plugin filename="ComponentInspector" name="Component inspector">
  <ignition-gui>
    <property type="bool" key="showTitleBar">false</property>
    <property type="string" key="state">docked</property>
  </ignition-gui>
</plugin>

<!-- Entity tree -->
<plugin filename="EntityTree" name="Entity tree">
  <ignition-gui>
    <property type="bool" key="showTitleBar">false</property>
    <property type="string" key="state">docked</property>
  </ignition-gui>
</plugin>
```

---

## Reconstruction

Follow these steps on a fresh machine to recreate all files from this document:

1. Create the project root directory:
   ```bash
   mkdir -p ros2-gazebo
   cd ros2-gazebo
   ```

2. Create the `config/` subdirectory:
   ```bash
   mkdir -p config
   ```

3. Place each file at the path shown in its section header above:
   - `Dockerfile` at `ros2-gazebo/Dockerfile`
   - `docker-compose.yml` at `ros2-gazebo/docker-compose.yml`
   - `entrypoint.sh` at `ros2-gazebo/entrypoint.sh`
   - `config/gz_gui.config` at `ros2-gazebo/config/gz_gui.config`

4. Make `entrypoint.sh` executable:
   ```bash
   chmod +x entrypoint.sh
   ```

5. The `Dockerfile` also expects `src/` (the ROS2 package) and `worlds/` directories to be present before building. Proceed to `02-ros2-package.md` for the ROS2 package files (`src/tb3_sim/`), then return here to build:
   ```bash
   docker compose build
   ```
