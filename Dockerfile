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
