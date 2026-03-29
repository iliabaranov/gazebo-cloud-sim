"""
TurtleBot3 Burger + NAV2 launch for Gazebo Harmonic.

Launches:
  1. Gazebo Harmonic with tb3_world.sdf  (world + embedded TurtleBot3 model)
  2. robot_state_publisher  (official TurtleBot3 URDF → TF tree)
  3. ros_gz_bridge  (scan 10Hz, odom, tf, clock, cmd_vel, joint_states, imu, camera 10Hz)
  3b. ros_gz_image/image_bridge  (camera — avoids 50% frame drop vs parameter_bridge)
  3c. rosbridge_websocket  (always-on WebSocket on :9090 for Foxglove Studio)
  4. NAV2 bringup  (map_server, AMCL, planner, controller, behaviours)
  5. random_goal_sender  (continuous random NavToPose goals)
"""

import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import ExecuteProcess, IncludeLaunchDescription, TimerAction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch_ros.actions import Node


def generate_launch_description():
    pkg = get_package_share_directory('tb3_sim')
    nav2_bringup = get_package_share_directory('nav2_bringup')

    world = os.path.join(pkg, 'worlds', 'tb3_world.sdf')
    nav2_params = os.path.join(pkg, 'params', 'nav2_params.yaml')
    map_yaml = os.path.join(pkg, 'maps', 'tb3_world.yaml')
    urdf_file = os.path.join(pkg, 'urdf', 'turtlebot3_burger.urdf')

    # Read URDF for robot_state_publisher (RSP ignores <gazebo> tags)
    with open(urdf_file, 'r') as f:
        robot_description = f.read()

    # ── 1. Gazebo server (headless, no GUI) ──────────────────────────────────
    # -s  = server only (no GUI process)
    # -r  = auto-start simulation
    # --headless-rendering = sensors use EGL directly, no X11/GLX needed
    # vglrun is NOT used: server uses EGL, not GLX. The GUI (started on-demand
    # by the VNC monitor in entrypoint.sh) uses vglrun when a VNC client connects.
    gazebo = ExecuteProcess(
        cmd=[
            'ros2', 'launch', 'ros_gz_sim', 'gz_sim.launch.py',
            f'gz_args:=-v 1 -s -r --headless-rendering {world}',
        ],
        output='screen',
    )

    # ── 2. Robot state publisher (official TurtleBot3 URDF kinematics) ────────
    robot_state_publisher = Node(
        package='robot_state_publisher',
        executable='robot_state_publisher',
        name='robot_state_publisher',
        output='screen',
        parameters=[{
            'use_sim_time': True,
            'robot_description': robot_description,
        }],
    )

    # ── 3. ros_gz_bridge ──────────────────────────────────────────────────────
    bridge = Node(
        package='ros_gz_bridge',
        executable='parameter_bridge',
        name='gz_bridge',
        output='screen',
        parameters=[{'use_sim_time': True}],
        arguments=[
            '/clock@rosgraph_msgs/msg/Clock[gz.msgs.Clock',
            '/scan@sensor_msgs/msg/LaserScan[gz.msgs.LaserScan',
            '/odom@nav_msgs/msg/Odometry[gz.msgs.Odometry',
            '/tf@tf2_msgs/msg/TFMessage[gz.msgs.Pose_V',
            '/cmd_vel@geometry_msgs/msg/Twist]gz.msgs.Twist',
            '/joint_states@sensor_msgs/msg/JointState[gz.msgs.Model',
            '/imu@sensor_msgs/msg/Imu[gz.msgs.IMU',
            '/camera/camera_info@sensor_msgs/msg/CameraInfo[gz.msgs.CameraInfo',
        ],
    )

    # ── 3b. ros_gz_image bridge (dedicated node for large image data) ─────────
    # Uses ros_gz_image which handles image transport more efficiently than
    # parameter_bridge, avoiding the ~50% frame drop seen with large images.
    image_bridge = Node(
        package='ros_gz_image',
        executable='image_bridge',
        name='gz_image_bridge',
        output='screen',
        arguments=['/camera/image_raw'],
        parameters=[{'use_sim_time': True}],
    )

    # ── 3c. rosbridge WebSocket (always-on, for Foxglove / web visualisation) ───
    # rosbridge_suite is in standard ROS2 Humble repos; foxglove_bridge is not.
    # Foxglove Studio connects via rosbridge WebSocket protocol (ws://host:9090).
    # Listens on 0.0.0.0:9090 inside the container.
    # The orchestrator maps this to host port FOXGLOVE_BASE_PORT + instance_id.
    # rosapi_node provides /rosapi/topics and friends — required by Foxglove.
    rosapi = Node(
        package='rosapi',
        executable='rosapi_node',
        name='rosapi',
        output='screen',
        parameters=[{'use_sim_time': True}],
    )
    foxglove_bridge = Node(
        package='rosbridge_server',
        executable='rosbridge_websocket',
        name='rosbridge_websocket',
        output='screen',
        parameters=[{
            'use_sim_time': True,
            'port': 9090,
            'address': '0.0.0.0',
        }],
    )

    # ── 4. NAV2 bringup ───────────────────────────────────────────────────────
    nav2 = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(nav2_bringup, 'launch', 'bringup_launch.py')
        ),
        launch_arguments={
            'use_sim_time': 'true',
            'autostart': 'true',
            'params_file': nav2_params,
            'map': map_yaml,
        }.items(),
    )

    # ── 5. Random goal sender (delayed 20s: NAV2 init + AMCL convergence) ─────
    goal_sender = TimerAction(
        period=20.0,
        actions=[
            Node(
                package='tb3_sim',
                executable='random_goal_sender.py',
                name='random_goal_sender',
                output='screen',
                parameters=[{
                    'use_sim_time': True,
                    'map_x_min': -2.0,
                    'map_x_max':  2.0,
                    'map_y_min': -2.0,
                    'map_y_max':  2.0,
                    'goal_timeout': 30.0,
                }],
            )
        ],
    )

    return LaunchDescription([
        gazebo,
        robot_state_publisher,
        bridge,
        image_bridge,
        rosapi,
        foxglove_bridge,
        nav2,
        goal_sender,
    ])
