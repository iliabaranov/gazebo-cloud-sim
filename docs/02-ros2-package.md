# ROS2 Package: tb3_sim

This document contains the full verbatim content of every source file in the `tb3_sim` ROS2
package. Its purpose is to allow someone on a fresh machine to recreate every file exactly.

The `tb3_sim` package provides the complete TurtleBot3 Burger simulation stack: the Gazebo
Harmonic SDF world, the robot URDF with embedded Gazebo plugins, the NAV2 parameter config,
the main launch file that wires everything together, and the `random_goal_sender` Python node
that drives the robot autonomously to random navigation goals.

---

## `src/tb3_sim/package.xml`

ROS2 package manifest declaring all build, exec, and test dependencies.

```xml
<?xml version="1.0"?>
<package format="3">
  <name>tb3_sim</name>
  <version>0.0.1</version>
  <description>TurtleBot3 Gazebo Harmonic + NAV2 simulation</description>
  <maintainer email="user@example.com">user</maintainer>
  <license>Apache-2.0</license>

  <depend>rclpy</depend>
  <depend>geometry_msgs</depend>
  <depend>nav2_msgs</depend>
  <depend>action_msgs</depend>
  <depend>nav_msgs</depend>
  <depend>std_msgs</depend>

  <exec_depend>ros_gz_sim</exec_depend>
  <exec_depend>ros_gz_bridge</exec_depend>
  <exec_depend>robot_state_publisher</exec_depend>
  <exec_depend>nav2_bringup</exec_depend>
  <exec_depend>slam_toolbox</exec_depend>

  <buildtool_depend>ament_cmake_python</buildtool_depend>
  <buildtool_depend>ament_cmake</buildtool_depend>

  <test_depend>ament_lint_auto</test_depend>
  <test_depend>ament_lint_common</test_depend>

  <export>
    <build_type>ament_cmake</build_type>
  </export>
</package>
```

---

## `src/tb3_sim/CMakeLists.txt`

CMake build file that installs the Python package, the goal sender script, and all data directories.

```cmake
cmake_minimum_required(VERSION 3.8)
project(tb3_sim)

find_package(ament_cmake REQUIRED)
find_package(ament_cmake_python REQUIRED)

ament_python_install_package(${PROJECT_NAME})

install(PROGRAMS
  tb3_sim/random_goal_sender.py
  DESTINATION lib/${PROJECT_NAME}
)

install(DIRECTORY
  launch
  worlds
  maps
  params
  urdf
  DESTINATION share/${PROJECT_NAME}
)

ament_package()
```

---

## `src/tb3_sim/tb3_sim/__init__.py`

Empty Python package init file (required by ament_cmake_python).

```python
```

---

## `src/tb3_sim/tb3_sim/random_goal_sender.py`

ROS2 node that continuously sends random `NavigateToPose` action goals to NAV2, with a watchdog timer and success/failure tracking.

```python
#!/usr/bin/env python3
"""
random_goal_sender — continuously sends random NavToPose goals to NAV2.

Uses a single persistent poll timer (0.5 Hz) instead of creating/destroying
timers, which avoids the rclpy InvalidHandle crash that occurs when
timer.cancel() is called from within a timer callback.
"""

import math
import random

import rclpy
from rclpy.node import Node
from rclpy.action import ActionClient
from rclpy.duration import Duration

from geometry_msgs.msg import PoseStamped
from nav2_msgs.action import NavigateToPose
from action_msgs.msg import GoalStatus


class RandomGoalSender(Node):
    def __init__(self):
        super().__init__('random_goal_sender')

        self.declare_parameter('map_x_min', -2.0)
        self.declare_parameter('map_x_max',  2.0)
        self.declare_parameter('map_y_min', -2.0)
        self.declare_parameter('map_y_max',  2.0)
        self.declare_parameter('goal_timeout', 30.0)

        self.x_min = self.get_parameter('map_x_min').value
        self.x_max = self.get_parameter('map_x_max').value
        self.y_min = self.get_parameter('map_y_min').value
        self.y_max = self.get_parameter('map_y_max').value
        self.goal_timeout = self.get_parameter('goal_timeout').value

        self._client = ActionClient(self, NavigateToPose, 'navigate_to_pose')
        self._goal_count = 0
        self._success_count = 0
        self._busy = False
        self._watchdog_timer = None

        # _send_after: clock time (nanoseconds) after which to send the next goal.
        # None means no pending send.  Set by _schedule_next().
        self._send_after = None

        # Single persistent poll timer — never destroyed, avoids InvalidHandle.
        self._poll_timer = self.create_timer(0.5, self._poll_cb)

        self.get_logger().info(
            f'Random goal sender ready. Map bounds: '
            f'x=[{self.x_min:.1f},{self.x_max:.1f}] y=[{self.y_min:.1f},{self.y_max:.1f}]'
        )

        # Schedule first goal 3 s after startup
        self._schedule_next(delay=3.0)

    # ── helpers ───────────────────────────────────────────────────────────────

    def _schedule_next(self, delay: float = 2.0):
        """Request the next goal to be sent after `delay` seconds."""
        if self._busy:
            return
        now_ns = self.get_clock().now().nanoseconds
        self._send_after = now_ns + int(delay * 1e9)

    def _poll_cb(self):
        """Called every 0.5 s. Triggers goal send when the scheduled time arrives."""
        if self._busy or self._send_after is None:
            return
        if self.get_clock().now().nanoseconds >= self._send_after:
            self._send_after = None
            self._send_next_goal()

    def _random_pose(self):
        x = random.uniform(self.x_min, self.x_max)
        y = random.uniform(self.y_min, self.y_max)
        yaw = random.uniform(-math.pi, math.pi)
        return x, y, yaw

    # ── goal lifecycle ────────────────────────────────────────────────────────

    def _send_next_goal(self):
        if self._busy:
            return
        self._busy = True

        if not self._client.wait_for_server(timeout_sec=5.0):
            self.get_logger().warn('NavigateToPose server not ready, retrying in 5 s…')
            self._busy = False
            self._schedule_next(delay=5.0)
            return

        x, y, yaw = self._random_pose()
        self._goal_count += 1

        self.get_logger().info(
            f'Goal #{self._goal_count}: x={x:.2f} y={y:.2f} yaw={yaw:.2f}'
        )

        goal_msg = NavigateToPose.Goal()
        goal_msg.pose = PoseStamped()
        goal_msg.pose.header.frame_id = 'map'
        goal_msg.pose.header.stamp = self.get_clock().now().to_msg()
        goal_msg.pose.pose.position.x = x
        goal_msg.pose.pose.position.y = y
        goal_msg.pose.pose.position.z = 0.0
        goal_msg.pose.pose.orientation.z = math.sin(yaw / 2.0)
        goal_msg.pose.pose.orientation.w = math.cos(yaw / 2.0)

        future = self._client.send_goal_async(
            goal_msg,
            feedback_callback=self._feedback_cb,
        )
        future.add_done_callback(self._goal_accepted_cb)

    def _feedback_cb(self, fb_msg):
        dist = fb_msg.feedback.distance_remaining
        self.get_logger().debug(f'  Distance remaining: {dist:.2f} m')

    def _goal_accepted_cb(self, future):
        handle = future.result()
        if not handle.accepted:
            self.get_logger().warn('Goal rejected — retrying in 5 s')
            self._busy = False
            self._schedule_next(delay=5.0)
            return

        self.get_logger().info('Goal accepted.')

        # Watchdog: cancel goal if it takes too long
        self._watchdog_timer = self.create_timer(
            self.goal_timeout, lambda: self._watchdog_cb(handle)
        )

        handle.get_result_async().add_done_callback(self._result_cb)

    def _watchdog_cb(self, handle):
        self.get_logger().warn(
            f'Goal timed out after {self.goal_timeout:.0f} s — cancelling.'
        )
        self._cancel_watchdog()
        handle.cancel_goal_async()
        self._busy = False
        self._schedule_next(delay=2.0)

    def _result_cb(self, future):
        self._cancel_watchdog()
        result = future.result()
        status = result.status

        if status == GoalStatus.STATUS_SUCCEEDED:
            self._success_count += 1
            self.get_logger().info(
                f'Goal #{self._goal_count} REACHED '
                f'({self._success_count}/{self._goal_count} succeeded)'
            )
        elif status == GoalStatus.STATUS_CANCELED:
            self.get_logger().info('Goal cancelled. Moving on.')
        else:
            self.get_logger().warn(f'Goal failed (status {status}). Moving on.')

        self._busy = False
        self._schedule_next(delay=2.0)

    def _cancel_watchdog(self):
        if self._watchdog_timer is not None:
            self._watchdog_timer.cancel()
            self._watchdog_timer.destroy()
            self._watchdog_timer = None


def main(args=None):
    rclpy.init(args=args)
    node = RandomGoalSender()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

---

## `src/tb3_sim/launch/tb3_nav2.launch.py`

Main launch file that starts Gazebo Harmonic, robot_state_publisher, the ROS-GZ bridge, NAV2, and the random goal sender.

```python
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
    # rosapi_node MUST run alongside rosbridge — it provides /rosapi/topics and
    # related services that Foxglove calls on connect. Without it, Foxglove
    # immediately disconnects ("service does not exist").
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
```

---

## `src/tb3_sim/params/nav2_params.yaml`

NAV2 parameter file configuring AMCL, BT Navigator, DWB controller, costmaps, planner, smoother, behavior server, waypoint follower, and velocity smoother.

```yaml
amcl:
  ros__parameters:
    use_sim_time: True
    alpha1: 0.2
    alpha2: 0.2
    alpha3: 0.2
    alpha4: 0.2
    alpha5: 0.2
    base_frame_id: "base_footprint"
    beam_skip_distance: 0.5
    beam_skip_error_threshold: 0.9
    beam_skip_threshold: 0.3
    do_beamskip: false
    global_frame_id: "map"
    lambda_short: 0.1
    laser_likelihood_max_dist: 2.0
    laser_max_range: 100.0
    laser_min_range: -1.0
    laser_model_type: "likelihood_field"
    max_beams: 60
    max_particles: 2000
    min_particles: 500
    odom_frame_id: "odom"
    pf_err: 0.05
    pf_z: 0.99
    recovery_alpha_fast: 0.0
    recovery_alpha_slow: 0.0
    resample_interval: 1
    robot_model_type: "nav2_amcl::DifferentialMotionModel"
    save_pose_rate: 0.5
    sigma_hit: 0.2
    tf_broadcast: true
    transform_tolerance: 1.0
    update_min_a: 0.2
    update_min_d: 0.25
    z_hit: 0.5
    z_max: 0.05
    z_rand: 0.5
    z_short: 0.05
    scan_topic: scan
    # Set initial pose to match where robot spawns in the SDF world
    set_initial_pose: true
    initial_pose:
      x: 0.0
      y: -2.0
      z: 0.0
      yaw: 0.0

bt_navigator:
  ros__parameters:
    use_sim_time: True
    global_frame: map
    robot_base_frame: base_footprint
    odom_topic: /odom
    bt_loop_duration: 10
    default_server_timeout: 20
    wait_for_service_timeout: 1000
    plugin_lib_names:
      - nav2_compute_path_to_pose_action_bt_node
      - nav2_compute_path_through_poses_action_bt_node
      - nav2_smooth_path_action_bt_node
      - nav2_follow_path_action_bt_node
      - nav2_spin_action_bt_node
      - nav2_wait_action_bt_node
      - nav2_assisted_teleop_action_bt_node
      - nav2_back_up_action_bt_node
      - nav2_drive_on_heading_bt_node
      - nav2_clear_costmap_service_bt_node
      - nav2_is_stuck_condition_bt_node
      - nav2_goal_reached_condition_bt_node
      - nav2_goal_updated_condition_bt_node
      - nav2_globally_updated_goal_condition_bt_node
      - nav2_is_path_valid_condition_bt_node
      - nav2_initial_pose_received_condition_bt_node
      - nav2_reinitialize_global_localization_service_bt_node
      - nav2_rate_controller_bt_node
      - nav2_distance_controller_bt_node
      - nav2_speed_controller_bt_node
      - nav2_truncate_path_action_bt_node
      - nav2_truncate_path_local_action_bt_node
      - nav2_goal_updater_node_bt_node
      - nav2_recovery_node_bt_node
      - nav2_pipeline_sequence_bt_node
      - nav2_round_robin_node_bt_node
      - nav2_transform_available_condition_bt_node
      - nav2_time_expired_condition_bt_node
      - nav2_path_expiring_timer_condition
      - nav2_distance_traveled_condition_bt_node
      - nav2_single_trigger_bt_node
      - nav2_goal_updated_controller_bt_node
      - nav2_is_battery_low_condition_bt_node
      - nav2_navigate_through_poses_action_bt_node
      - nav2_navigate_to_pose_action_bt_node
      - nav2_remove_passed_goals_action_bt_node
      - nav2_planner_selector_bt_node
      - nav2_controller_selector_bt_node
      - nav2_goal_checker_selector_bt_node
      - nav2_controller_cancel_bt_node
      - nav2_path_longer_on_approach_bt_node
      - nav2_wait_cancel_bt_node
      - nav2_spin_cancel_bt_node
      - nav2_back_up_cancel_bt_node
      - nav2_assisted_teleop_cancel_bt_node
      - nav2_drive_on_heading_cancel_bt_node
      - nav2_is_battery_charging_condition_bt_node

bt_navigator_navigate_through_poses_rclcpp_node:
  ros__parameters:
    use_sim_time: True

bt_navigator_navigate_to_pose_rclcpp_node:
  ros__parameters:
    use_sim_time: True

controller_server:
  ros__parameters:
    use_sim_time: True
    controller_frequency: 20.0
    min_x_velocity_threshold: 0.001
    min_y_velocity_threshold: 0.5
    min_theta_velocity_threshold: 0.001
    failure_tolerance: 0.3
    progress_checker_plugin: "progress_checker"
    goal_checker_plugins: ["general_goal_checker"]
    controller_plugins: ["FollowPath"]
    progress_checker:
      plugin: "nav2_controller::SimpleProgressChecker"
      required_movement_radius: 0.5
      movement_time_allowance: 10.0
    general_goal_checker:
      stateful: True
      plugin: "nav2_controller::SimpleGoalChecker"
      xy_goal_tolerance: 0.25
      yaw_goal_tolerance: 0.25
    FollowPath:
      plugin: "dwb_core::DWBLocalPlanner"
      debug_trajectory_details: True
      min_vel_x: 0.0
      min_vel_y: 0.0
      max_vel_x: 0.26
      max_vel_y: 0.0
      max_vel_theta: 1.0
      min_speed_xy: 0.0
      max_speed_xy: 0.26
      min_speed_theta: 0.0
      acc_lim_x: 2.5
      acc_lim_y: 0.0
      acc_lim_theta: 3.2
      decel_lim_x: -2.5
      decel_lim_y: 0.0
      decel_lim_theta: -3.2
      vx_samples: 20
      vy_samples: 5
      vtheta_samples: 20
      sim_time: 1.7
      linear_granularity: 0.05
      angular_granularity: 0.025
      transform_tolerance: 0.2
      xy_goal_tolerance: 0.25
      trans_stopped_velocity: 0.25
      short_circuit_trajectory_evaluation: True
      stateful: True
      critics: ["RotateToGoal", "Oscillation", "BaseObstacle", "GoalAlign", "PathAlign", "PathDist", "GoalDist"]
      BaseObstacle.scale: 0.02
      PathAlign.scale: 32.0
      PathAlign.forward_point_distance: 0.1
      GoalAlign.scale: 24.0
      GoalAlign.forward_point_distance: 0.1
      PathDist.scale: 32.0
      GoalDist.scale: 24.0
      RotateToGoal.scale: 32.0
      RotateToGoal.slowing_factor: 5.0
      RotateToGoal.lookahead_time: -1.0

local_costmap:
  local_costmap:
    ros__parameters:
      update_frequency: 5.0
      publish_frequency: 2.0
      global_frame: odom
      robot_base_frame: base_footprint
      use_sim_time: True
      rolling_window: true
      width: 3
      height: 3
      resolution: 0.05
      robot_radius: 0.22
      plugins: ["voxel_layer", "inflation_layer"]
      inflation_layer:
        plugin: "nav2_costmap_2d::InflationLayer"
        cost_scaling_factor: 3.0
        inflation_radius: 0.55
      voxel_layer:
        plugin: "nav2_costmap_2d::VoxelLayer"
        enabled: True
        publish_voxel_map: True
        origin_z: 0.0
        z_resolution: 0.05
        z_voxels: 16
        max_obstacle_height: 2.0
        mark_threshold: 0
        observation_sources: scan
        scan:
          topic: /scan
          max_obstacle_height: 2.0
          clearing: True
          marking: True
          data_type: "LaserScan"
          raytrace_max_range: 3.0
          raytrace_min_range: 0.0
          obstacle_max_range: 2.5
          obstacle_min_range: 0.0
      static_layer:
        plugin: "nav2_costmap_2d::StaticLayer"
        map_subscribe_transient_local: True
      always_send_full_costmap: True

global_costmap:
  global_costmap:
    ros__parameters:
      update_frequency: 1.0
      publish_frequency: 1.0
      global_frame: map
      robot_base_frame: base_footprint
      use_sim_time: True
      robot_radius: 0.22
      resolution: 0.05
      track_unknown_space: true
      plugins: ["static_layer", "obstacle_layer", "inflation_layer"]
      obstacle_layer:
        plugin: "nav2_costmap_2d::ObstacleLayer"
        enabled: True
        observation_sources: scan
        scan:
          topic: /scan
          max_obstacle_height: 2.0
          clearing: True
          marking: True
          data_type: "LaserScan"
          raytrace_max_range: 3.0
          raytrace_min_range: 0.0
          obstacle_max_range: 2.5
          obstacle_min_range: 0.0
      static_layer:
        plugin: "nav2_costmap_2d::StaticLayer"
        map_subscribe_transient_local: True
      inflation_layer:
        plugin: "nav2_costmap_2d::InflationLayer"
        cost_scaling_factor: 3.0
        inflation_radius: 0.55
      always_send_full_costmap: True

map_server:
  ros__parameters:
    use_sim_time: True
    yaml_filename: /ros2_ws/install/tb3_sim/share/tb3_sim/maps/tb3_world.yaml

map_saver:
  ros__parameters:
    use_sim_time: True
    save_map_timeout: 5.0
    free_thresh_default: 0.25
    occupied_thresh_default: 0.65
    map_subscribe_transient_local: True

planner_server:
  ros__parameters:
    expected_planner_frequency: 20.0
    use_sim_time: True
    planner_plugins: ["GridBased"]
    GridBased:
      plugin: "nav2_navfn_planner/NavfnPlanner"
      tolerance: 0.5
      use_astar: false
      allow_unknown: true

smoother_server:
  ros__parameters:
    use_sim_time: True
    smoother_plugins: ["simple_smoother"]
    simple_smoother:
      plugin: "nav2_smoother::SimpleSmoother"
      tolerance: 1.0e-10
      max_its: 1000
      do_refinement: True

behavior_server:
  ros__parameters:
    costmap_topic: local_costmap/costmap_raw
    footprint_topic: local_costmap/published_footprint
    cycle_frequency: 10.0
    behavior_plugins: ["spin", "backup", "drive_on_heading", "assisted_teleop", "wait"]
    spin:
      plugin: "nav2_behaviors/Spin"
    backup:
      plugin: "nav2_behaviors/BackUp"
    drive_on_heading:
      plugin: "nav2_behaviors/DriveOnHeading"
    wait:
      plugin: "nav2_behaviors/Wait"
    assisted_teleop:
      plugin: "nav2_behaviors/AssistedTeleop"
    global_frame: odom
    robot_base_frame: base_footprint
    transform_tolerance: 0.1
    use_sim_time: true
    simulate_ahead_time: 2.0
    max_rotational_vel: 1.0
    min_rotational_vel: 0.4
    rotational_acc_lim: 3.2

waypoint_follower:
  ros__parameters:
    use_sim_time: True
    loop_rate: 20
    stop_on_failure: false
    action_server_result_timeout: 900.0
    waypoint_task_executor_plugin: "wait_at_waypoint"
    wait_at_waypoint:
      plugin: "nav2_waypoint_follower::WaitAtWaypoint"
      enabled: True
      waypoint_pause_duration: 200

velocity_smoother:
  ros__parameters:
    use_sim_time: True
    smoothing_frequency: 20.0
    scale_velocities: False
    feedback: "OPEN_LOOP"
    max_velocity: [0.26, 0.0, 1.0]
    min_velocity: [-0.26, 0.0, -1.0]
    max_accel: [2.5, 0.0, 3.2]
    max_decel: [-2.5, 0.0, -3.2]
    odom_topic: "odom"
    odom_duration: 0.1
    deadband_velocity: [0.0, 0.0, 0.0]
    velocity_timeout: 1.0
```

---

## `src/tb3_sim/maps/tb3_world.yaml`

NAV2 map metadata file pointing to the binary occupancy grid image.

```yaml
image: tb3_world.pgm
resolution: 0.05
origin: [-3.0, -3.0, 0.0]
negate: 0
occupied_thresh: 0.65
free_thresh: 0.196
```

---

## `src/tb3_sim/urdf/turtlebot3_burger.urdf`

TurtleBot3 Burger URDF with kinematics matching the official turtlebot3_description package, plus embedded Gazebo Harmonic plugins for differential drive, LiDAR, IMU, and RGB camera.

```xml
<?xml version="1.0"?>
<!--
  TurtleBot3 Burger URDF for Gazebo Harmonic + NAV2 (ROS2 Humble)

  Kinematics and inertia match the official turtlebot3_description package.
  Gazebo plugins (DiffDrive, LiDAR 10Hz, IMU, Camera 10Hz) are embedded
  via <gazebo> tags so the robot can be spawned from this single file.
-->
<robot name="turtlebot3_burger">

  <!-- ── Base frames ──────────────────────────────────────────────────────── -->

  <link name="base_footprint"/>

  <joint name="base_joint" type="fixed">
    <parent link="base_footprint"/>
    <child link="base_link"/>
    <origin xyz="0 0 0.010" rpy="0 0 0"/>
  </joint>

  <link name="base_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="8.2573504e-01"/>
      <inertia ixx="2.2124416e-03" ixy="-1.2294101e-05" ixz="3.4938785e-05"
               iyy="2.1193702e-03" iyz="-5.0120904e-06" izz="2.0064271e-03"/>
    </inertial>
    <!-- Collision box matches physical burger chassis -->
    <collision>
      <origin xyz="-0.032 0 0.070" rpy="0 0 0"/>
      <geometry><box size="0.140 0.140 0.143"/></geometry>
    </collision>
    <visual>
      <origin xyz="-0.032 0 0.070" rpy="0 0 0"/>
      <geometry><box size="0.140 0.140 0.143"/></geometry>
      <material name="light_black"><color rgba="0.4 0.4 0.4 1.0"/></material>
    </visual>
  </link>

  <!-- ── Wheels ────────────────────────────────────────────────────────────── -->

  <joint name="wheel_left_joint" type="continuous">
    <parent link="base_link"/>
    <child link="wheel_left_link"/>
    <origin xyz="0 0.08 0.023" rpy="-1.5708 0 0"/>
    <axis xyz="0 0 1"/>
  </joint>

  <link name="wheel_left_link">
    <inertial>
      <origin xyz="0 0 0"/>
      <mass value="2.8498940e-02"/>
      <inertia ixx="1.1175580e-05" ixy="-4.2369783e-11" ixz="-5.9381719e-09"
               iyy="1.1192413e-05" iyz="-1.4400107e-11" izz="2.0712558e-05"/>
    </inertial>
    <collision>
      <geometry><cylinder length="0.018" radius="0.033"/></geometry>
    </collision>
    <visual>
      <geometry><cylinder length="0.018" radius="0.033"/></geometry>
      <material name="dark"><color rgba="0.2 0.2 0.2 1.0"/></material>
    </visual>
  </link>

  <joint name="wheel_right_joint" type="continuous">
    <parent link="base_link"/>
    <child link="wheel_right_link"/>
    <origin xyz="0 -0.08 0.023" rpy="-1.5708 0 0"/>
    <axis xyz="0 0 1"/>
  </joint>

  <link name="wheel_right_link">
    <inertial>
      <origin xyz="0 0 0"/>
      <mass value="2.8498940e-02"/>
      <inertia ixx="1.1175580e-05" ixy="-4.2369783e-11" ixz="-5.9381719e-09"
               iyy="1.1192413e-05" iyz="-1.4400107e-11" izz="2.0712558e-05"/>
    </inertial>
    <collision>
      <geometry><cylinder length="0.018" radius="0.033"/></geometry>
    </collision>
    <visual>
      <geometry><cylinder length="0.018" radius="0.033"/></geometry>
      <material name="dark"><color rgba="0.2 0.2 0.2 1.0"/></material>
    </visual>
  </link>

  <!-- ── Caster (single, official position) ────────────────────────────────── -->

  <joint name="caster_back_joint" type="fixed">
    <parent link="base_link"/>
    <child link="caster_back_link"/>
    <origin xyz="-0.081 0 -0.004" rpy="-1.5708 0 0"/>
  </joint>

  <link name="caster_back_link">
    <inertial>
      <origin xyz="0 0 0"/>
      <mass value="0.005"/>
      <inertia ixx="0.001" ixy="0" ixz="0" iyy="0.001" iyz="0" izz="0.001"/>
    </inertial>
    <collision>
      <origin xyz="0 0.001 0" rpy="0 0 0"/>
      <geometry><box size="0.030 0.009 0.020"/></geometry>
    </collision>
  </link>

  <!-- ── IMU ───────────────────────────────────────────────────────────────── -->

  <joint name="imu_joint" type="fixed">
    <parent link="base_link"/>
    <child link="imu_link"/>
    <origin xyz="-0.032 0 0.068" rpy="0 0 0"/>
  </joint>

  <link name="imu_link">
    <inertial>
      <mass value="0.001"/>
      <inertia ixx="0.00001" ixy="0" ixz="0" iyy="0.00001" iyz="0" izz="0.00001"/>
    </inertial>
  </link>

  <!-- ── LiDAR ─────────────────────────────────────────────────────────────── -->
  <!-- Official position from turtlebot3_description scan_joint -->

  <joint name="scan_joint" type="fixed">
    <parent link="base_link"/>
    <child link="base_scan"/>
    <origin xyz="-0.032 0 0.172" rpy="0 0 0"/>
  </joint>

  <link name="base_scan">
    <inertial>
      <mass value="0.114"/>
      <origin xyz="0 0 0"/>
      <inertia ixx="0.001" ixy="0" ixz="0" iyy="0.001" iyz="0" izz="0.001"/>
    </inertial>
    <collision>
      <origin xyz="0 0 -0.0065" rpy="0 0 0"/>
      <geometry><cylinder length="0.0315" radius="0.055"/></geometry>
    </collision>
    <visual>
      <origin xyz="0 0 -0.0065" rpy="0 0 0"/>
      <geometry><cylinder length="0.0315" radius="0.055"/></geometry>
      <material name="dark"><color rgba="0.1 0.1 0.1 1.0"/></material>
    </visual>
  </link>

  <!-- ── Camera ────────────────────────────────────────────────────────────── -->
  <!-- Mounted at the front of the robot, facing forward -->

  <joint name="camera_joint" type="fixed">
    <parent link="base_link"/>
    <child link="camera_link"/>
    <origin xyz="0.064 0 0.094" rpy="0 0 0"/>
  </joint>

  <link name="camera_link">
    <inertial>
      <mass value="0.015"/>
      <origin xyz="0 0 0"/>
      <inertia ixx="0.0001" ixy="0" ixz="0" iyy="0.0001" iyz="0" izz="0.0001"/>
    </inertial>
    <collision>
      <geometry><box size="0.025 0.090 0.025"/></geometry>
    </collision>
    <visual>
      <geometry><box size="0.025 0.090 0.025"/></geometry>
      <material name="blue"><color rgba="0.0 0.0 0.8 1.0"/></material>
    </visual>
  </link>

  <!-- Standard ROS camera optical frame (Z forward, X right, Y down) -->
  <joint name="camera_optical_joint" type="fixed">
    <parent link="camera_link"/>
    <child link="camera_optical_frame"/>
    <origin xyz="0 0 0" rpy="-1.5708 0 -1.5708"/>
  </joint>

  <link name="camera_optical_frame"/>

  <!-- ═══════════════════════════════════════════════════════════════════════ -->
  <!-- Gazebo plugins                                                          -->
  <!-- ═══════════════════════════════════════════════════════════════════════ -->

  <!-- Differential drive (model-level plugin) -->
  <gazebo>
    <plugin filename="gz-sim-diff-drive-system" name="gz::sim::systems::DiffDrive">
      <left_joint>wheel_left_joint</left_joint>
      <right_joint>wheel_right_joint</right_joint>
      <wheel_separation>0.160</wheel_separation>
      <wheel_radius>0.033</wheel_radius>
      <odom_publish_frequency>20</odom_publish_frequency>
      <topic>cmd_vel</topic>
      <odom_topic>odom</odom_topic>
      <tf_topic>tf</tf_topic>
      <frame_id>odom</frame_id>
      <child_frame_id>base_footprint</child_frame_id>
      <min_acceleration>-1</min_acceleration>
      <max_acceleration>1</max_acceleration>
    </plugin>
  </gazebo>

  <!-- Joint state publisher (model-level plugin) -->
  <gazebo>
    <plugin filename="gz-sim-joint-state-publisher-system" name="gz::sim::systems::JointStatePublisher">
      <topic>joint_states</topic>
      <joint_name>wheel_left_joint</joint_name>
      <joint_name>wheel_right_joint</joint_name>
    </plugin>
  </gazebo>

  <!-- Zero friction on caster -->
  <gazebo reference="caster_back_link">
    <mu1>0.0</mu1>
    <mu2>0.0</mu2>
  </gazebo>

  <!-- LiDAR sensor (10 Hz, 360°) -->
  <gazebo reference="base_scan">
    <sensor name="lidar" type="gpu_lidar">
      <always_on>true</always_on>
      <visualize>true</visualize>
      <update_rate>10</update_rate>
      <ray>
        <scan>
          <horizontal>
            <samples>360</samples>
            <resolution>1</resolution>
            <min_angle>-3.14159265</min_angle>
            <max_angle>3.14159265</max_angle>
          </horizontal>
        </scan>
        <range>
          <min>0.12</min>
          <max>3.5</max>
          <resolution>0.015</resolution>
        </range>
        <noise>
          <type>gaussian</type>
          <mean>0.0</mean>
          <stddev>0.01</stddev>
        </noise>
      </ray>
      <topic>scan</topic>
    </sensor>
  </gazebo>

  <!-- IMU sensor (200 Hz) -->
  <gazebo reference="imu_link">
    <sensor name="imu" type="imu">
      <always_on>true</always_on>
      <update_rate>200</update_rate>
      <topic>imu</topic>
    </sensor>
  </gazebo>

  <!-- RGB Camera sensor (10 Hz, 640×480, 80° FOV) -->
  <gazebo reference="camera_link">
    <sensor name="camera" type="camera">
      <always_on>true</always_on>
      <update_rate>10</update_rate>
      <camera>
        <horizontal_fov>1.3962634</horizontal_fov>
        <image>
          <width>640</width>
          <height>480</height>
          <format>R8G8B8</format>
        </image>
        <clip>
          <near>0.02</near>
          <far>300</far>
        </clip>
        <noise>
          <type>gaussian</type>
          <mean>0.0</mean>
          <stddev>0.007</stddev>
        </noise>
      </camera>
      <topic>camera/image_raw</topic>
    </sensor>
  </gazebo>

</robot>
```

---

## `src/tb3_sim/worlds/tb3_world.sdf`

Gazebo Harmonic SDF world: a 6x6m room with four corner boxes and a central pillar, plus the full TurtleBot3 Burger model embedded with all sensors and drive plugins.

```xml
<?xml version="1.0" ?>
<sdf version="1.8">
  <world name="turtlebot3_world">

    <!-- Physics: 50 Hz is sufficient for TurtleBot3 at NAV2 speeds (0.2-0.5 m/s).
         Halving from 100 Hz saves ~40% of physics thread CPU. -->
    <physics name="50hz" type="ignored">
      <max_step_size>0.02</max_step_size>
      <real_time_factor>1.0</real_time_factor>
      <real_time_update_rate>50</real_time_update_rate>
    </physics>

    <!-- World system plugins -->
    <plugin filename="gz-sim-physics-system"             name="gz::sim::systems::Physics"/>
    <plugin filename="gz-sim-scene-broadcaster-system"   name="gz::sim::systems::SceneBroadcaster"/>
    <plugin filename="gz-sim-user-commands-system"       name="gz::sim::systems::UserCommands"/>
    <!-- Sensors system: must use ignition- prefix for ign gazebo 6 plugin search path -->
    <plugin filename="ignition-gazebo-sensors-system"    name="ignition::gazebo::systems::Sensors">
      <render_engine>ogre2</render_engine>
    </plugin>
    <plugin filename="ignition-gazebo-imu-system"        name="ignition::gazebo::systems::Imu"/>
    <plugin filename="gz-sim-contact-system"             name="gz::sim::systems::Contact"/>

    <!-- Lighting -->
    <light type="directional" name="sun">
      <cast_shadows>true</cast_shadows>
      <pose>0 0 10 0 0 0</pose>
      <diffuse>0.8 0.8 0.8 1</diffuse>
      <specular>0.2 0.2 0.2 1</specular>
      <direction>-0.5 0.1 -0.9</direction>
    </light>

    <!-- Ground plane -->
    <model name="ground_plane">
      <static>true</static>
      <link name="link">
        <collision name="collision">
          <geometry><plane><normal>0 0 1</normal><size>100 100</size></plane></geometry>
        </collision>
        <visual name="visual">
          <geometry><plane><normal>0 0 1</normal><size>100 100</size></plane></geometry>
          <material>
            <ambient>0.8 0.8 0.8 1</ambient>
            <diffuse>0.8 0.8 0.8 1</diffuse>
          </material>
        </visual>
      </link>
    </model>

    <!-- Outer walls: 6m x 6m room -->
    <model name="wall_south">
      <static>true</static>
      <pose>0 -3 0.1 0 0 0</pose>
      <link name="link">
        <collision name="col"><geometry><box><size>6 0.05 0.2</size></box></geometry></collision>
        <visual name="vis">
          <geometry><box><size>6 0.05 0.2</size></box></geometry>
          <material><ambient>0.3 0.3 0.3 1</ambient><diffuse>0.5 0.5 0.5 1</diffuse></material>
        </visual>
      </link>
    </model>

    <model name="wall_north">
      <static>true</static>
      <pose>0 3 0.1 0 0 0</pose>
      <link name="link">
        <collision name="col"><geometry><box><size>6 0.05 0.2</size></box></geometry></collision>
        <visual name="vis">
          <geometry><box><size>6 0.05 0.2</size></box></geometry>
          <material><ambient>0.3 0.3 0.3 1</ambient><diffuse>0.5 0.5 0.5 1</diffuse></material>
        </visual>
      </link>
    </model>

    <model name="wall_west">
      <static>true</static>
      <pose>-3 0 0.1 0 0 1.5708</pose>
      <link name="link">
        <collision name="col"><geometry><box><size>6 0.05 0.2</size></box></geometry></collision>
        <visual name="vis">
          <geometry><box><size>6 0.05 0.2</size></box></geometry>
          <material><ambient>0.3 0.3 0.3 1</ambient><diffuse>0.5 0.5 0.5 1</diffuse></material>
        </visual>
      </link>
    </model>

    <model name="wall_east">
      <static>true</static>
      <pose>3 0 0.1 0 0 1.5708</pose>
      <link name="link">
        <collision name="col"><geometry><box><size>6 0.05 0.2</size></box></geometry></collision>
        <visual name="vis">
          <geometry><box><size>6 0.05 0.2</size></box></geometry>
          <material><ambient>0.3 0.3 0.3 1</ambient><diffuse>0.5 0.5 0.5 1</diffuse></material>
        </visual>
      </link>
    </model>

    <!-- Interior obstacles -->
    <model name="box1">
      <static>true</static>
      <pose>-1.5 1.5 0.15 0 0 0</pose>
      <link name="link">
        <collision name="col"><geometry><box><size>0.3 0.3 0.3</size></box></geometry></collision>
        <visual name="vis">
          <geometry><box><size>0.3 0.3 0.3</size></box></geometry>
          <material><ambient>0.8 0.2 0.2 1</ambient><diffuse>0.8 0.2 0.2 1</diffuse></material>
        </visual>
      </link>
    </model>

    <model name="box2">
      <static>true</static>
      <pose>1.5 -1.5 0.15 0 0 0</pose>
      <link name="link">
        <collision name="col"><geometry><box><size>0.3 0.3 0.3</size></box></geometry></collision>
        <visual name="vis">
          <geometry><box><size>0.3 0.3 0.3</size></box></geometry>
          <material><ambient>0.2 0.2 0.8 1</ambient><diffuse>0.2 0.2 0.8 1</diffuse></material>
        </visual>
      </link>
    </model>

    <model name="box3">
      <static>true</static>
      <pose>1.5 1.5 0.15 0 0 0</pose>
      <link name="link">
        <collision name="col"><geometry><box><size>0.3 0.3 0.3</size></box></geometry></collision>
        <visual name="vis">
          <geometry><box><size>0.3 0.3 0.3</size></box></geometry>
          <material><ambient>0.2 0.8 0.2 1</ambient><diffuse>0.2 0.8 0.2 1</diffuse></material>
        </visual>
      </link>
    </model>

    <model name="box4">
      <static>true</static>
      <pose>-1.5 -1.5 0.15 0 0 0</pose>
      <link name="link">
        <collision name="col"><geometry><box><size>0.3 0.3 0.3</size></box></geometry></collision>
        <visual name="vis">
          <geometry><box><size>0.3 0.3 0.3</size></box></geometry>
          <material><ambient>0.8 0.8 0.2 1</ambient><diffuse>0.8 0.8 0.2 1</diffuse></material>
        </visual>
      </link>
    </model>

    <!-- Central column -->
    <model name="pillar">
      <static>true</static>
      <pose>0 0 0.25 0 0 0</pose>
      <link name="link">
        <collision name="col"><geometry><cylinder><radius>0.12</radius><length>0.5</length></cylinder></geometry></collision>
        <visual name="vis">
          <geometry><cylinder><radius>0.12</radius><length>0.5</length></cylinder></geometry>
          <material><ambient>0.6 0.4 0.2 1</ambient><diffuse>0.6 0.4 0.2 1</diffuse></material>
        </visual>
      </link>
    </model>

    <!-- ═══════════════════════════════════════════════════════════════════════
         TurtleBot3 Burger
         All link poses are relative to the model origin (= base_footprint).

         Correct positions from official turtlebot3_description URDF:
           base_joint:  xyz="0 0 0.010"
           wheel_left:  xyz="0  0.08 0.023" from base_link → abs z = 0.010+0.023 = 0.033
           wheel_right: xyz="0 -0.08 0.023" from base_link → abs z = 0.033
           caster:      xyz="-0.081 0 -0.004" from base_link → abs z = 0.010-0.004 = 0.006
           imu:         xyz="-0.032 0 0.068" from base_link → abs z = 0.078
           base_scan:   xyz="-0.032 0 0.172" from base_link → abs z = 0.182
           camera:      xyz="0.064 0 0.094" from base_link → abs z = 0.104
         ═══════════════════════════════════════════════════════════════════════ -->
    <model name="turtlebot3">
      <pose>0 -2 0 0 0 0</pose>

      <!-- base_footprint: virtual ground-contact reference frame -->
      <link name="base_footprint">
        <pose>0 0 0 0 0 0</pose>
        <inertial><mass>0.001</mass></inertial>
      </link>

      <!-- base_link: main chassis -->
      <link name="base_link">
        <pose>0 0 0.010 0 0 0</pose>
        <inertial>
          <mass>8.2573504e-01</mass>
          <inertia>
            <ixx>2.2124416e-03</ixx><ixy>-1.2294101e-05</ixy><ixz>3.4938785e-05</ixz>
            <iyy>2.1193702e-03</iyy><iyz>-5.0120904e-06</iyz>
            <izz>2.0064271e-03</izz>
          </inertia>
        </inertial>
        <collision name="base_collision">
          <!-- Offset matches official URDF: -0.032 from link origin, 0.070 height center -->
          <pose>-0.032 0 0.070 0 0 0</pose>
          <geometry><box><size>0.140 0.140 0.143</size></box></geometry>
        </collision>
        <visual name="base_visual">
          <pose>-0.032 0 0.070 0 0 0</pose>
          <geometry><box><size>0.140 0.140 0.143</size></box></geometry>
          <material><ambient>0.4 0.4 0.4 1</ambient><diffuse>0.5 0.5 0.5 1</diffuse></material>
        </visual>
      </link>

      <joint name="base_joint" type="fixed">
        <parent>base_footprint</parent><child>base_link</child>
      </joint>

      <!-- Left wheel: abs z = 0.033 = wheel_radius (wheels just touch ground) -->
      <link name="wheel_left_link">
        <pose>0 0.08 0.033 -1.5708 0 0</pose>
        <inertial>
          <mass>2.8498940e-02</mass>
          <inertia>
            <ixx>1.1175580e-05</ixx><ixy>-4.2369783e-11</ixy><ixz>-5.9381719e-09</ixz>
            <iyy>1.1192413e-05</iyy><iyz>-1.4400107e-11</iyz><izz>2.0712558e-05</izz>
          </inertia>
        </inertial>
        <collision name="col">
          <geometry><cylinder><radius>0.033</radius><length>0.018</length></cylinder></geometry>
          <surface><friction><ode><mu>100</mu><mu2>100</mu2></ode></friction></surface>
        </collision>
        <visual name="vis">
          <geometry><cylinder><radius>0.033</radius><length>0.018</length></cylinder></geometry>
          <material><ambient>0.2 0.2 0.2 1</ambient><diffuse>0.2 0.2 0.2 1</diffuse></material>
        </visual>
      </link>

      <joint name="wheel_left_joint" type="revolute">
        <parent>base_link</parent><child>wheel_left_link</child>
        <axis><xyz>0 0 1</xyz><limit><effort>1</effort><velocity>100</velocity></limit></axis>
      </joint>

      <!-- Right wheel: abs z = 0.033 -->
      <link name="wheel_right_link">
        <pose>0 -0.08 0.033 -1.5708 0 0</pose>
        <inertial>
          <mass>2.8498940e-02</mass>
          <inertia>
            <ixx>1.1175580e-05</ixx><ixy>-4.2369783e-11</ixy><ixz>-5.9381719e-09</ixz>
            <iyy>1.1192413e-05</iyy><iyz>-1.4400107e-11</iyz><izz>2.0712558e-05</izz>
          </inertia>
        </inertial>
        <collision name="col">
          <geometry><cylinder><radius>0.033</radius><length>0.018</length></cylinder></geometry>
          <surface><friction><ode><mu>100</mu><mu2>100</mu2></ode></friction></surface>
        </collision>
        <visual name="vis">
          <geometry><cylinder><radius>0.033</radius><length>0.018</length></cylinder></geometry>
          <material><ambient>0.2 0.2 0.2 1</ambient><diffuse>0.2 0.2 0.2 1</diffuse></material>
        </visual>
      </link>

      <joint name="wheel_right_joint" type="revolute">
        <parent>base_link</parent><child>wheel_right_link</child>
        <axis><xyz>0 0 1</xyz><limit><effort>1</effort><velocity>100</velocity></limit></axis>
      </joint>

      <!-- Caster: abs z = 0.006, ball joint, zero friction -->
      <link name="caster_back_link">
        <pose>-0.081 0 0.006 0 0 0</pose>
        <inertial>
          <mass>0.005</mass>
          <inertia><ixx>0.001</ixx><iyy>0.001</iyy><izz>0.001</izz></inertia>
        </inertial>
        <collision name="col">
          <geometry><sphere><radius>0.006</radius></sphere></geometry>
          <surface><friction><ode><mu>0</mu><mu2>0</mu2></ode></friction></surface>
        </collision>
        <visual name="vis">
          <geometry><sphere><radius>0.006</radius></sphere></geometry>
          <material><ambient>0.5 0.5 0.5 1</ambient></material>
        </visual>
      </link>

      <joint name="caster_back_joint" type="ball">
        <parent>base_link</parent><child>caster_back_link</child>
      </joint>

      <!-- IMU link: abs z = 0.010 + 0.068 = 0.078 -->
      <link name="imu_link">
        <pose>-0.032 0 0.078 0 0 0</pose>
        <inertial><mass>0.001</mass><inertia><ixx>0.00001</ixx><iyy>0.00001</iyy><izz>0.00001</izz></inertia></inertial>
        <sensor name="imu" type="imu">
          <always_on>true</always_on>
          <update_rate>200</update_rate>
          <topic>imu</topic>
          <gz_frame_id>imu_link</gz_frame_id>
        </sensor>
      </link>

      <joint name="imu_joint" type="fixed">
        <parent>base_link</parent><child>imu_link</child>
      </joint>

      <!-- LiDAR link: abs z = 0.010 + 0.172 = 0.182 (official turtlebot3 position) -->
      <link name="base_scan">
        <pose>-0.032 0 0.182 0 0 0</pose>
        <inertial>
          <mass>0.114</mass>
          <inertia><ixx>0.001</ixx><iyy>0.001</iyy><izz>0.001</izz></inertia>
        </inertial>
        <collision name="col">
          <geometry><cylinder><radius>0.055</radius><length>0.0315</length></cylinder></geometry>
        </collision>
        <visual name="vis">
          <geometry><cylinder><radius>0.055</radius><length>0.0315</length></cylinder></geometry>
          <material><ambient>0.1 0.1 0.1 1</ambient><diffuse>0.1 0.1 0.1 1</diffuse></material>
        </visual>

        <sensor name="lidar" type="gpu_lidar">
          <always_on>true</always_on>
          <visualize>true</visualize>
          <update_rate>10</update_rate>
          <ray>
            <scan>
              <horizontal>
                <samples>360</samples>
                <resolution>1</resolution>
                <min_angle>-3.14159265</min_angle>
                <max_angle>3.14159265</max_angle>
              </horizontal>
            </scan>
            <range>
              <min>0.12</min>
              <max>3.5</max>
              <resolution>0.015</resolution>
            </range>
            <noise>
              <type>gaussian</type>
              <mean>0.0</mean>
              <stddev>0.01</stddev>
            </noise>
          </ray>
          <topic>scan</topic>
          <gz_frame_id>base_scan</gz_frame_id>
        </sensor>
      </link>

      <joint name="scan_joint" type="fixed">
        <parent>base_link</parent><child>base_scan</child>
      </joint>

      <!-- Camera link: abs z = 0.010 + 0.094 = 0.104, front of robot -->
      <link name="camera_link">
        <pose>0.064 0 0.104 0 0 0</pose>
        <inertial>
          <mass>0.015</mass>
          <inertia><ixx>0.0001</ixx><iyy>0.0001</iyy><izz>0.0001</izz></inertia>
        </inertial>
        <collision name="col">
          <geometry><box><size>0.025 0.090 0.025</size></box></geometry>
        </collision>
        <visual name="vis">
          <geometry><box><size>0.025 0.090 0.025</size></box></geometry>
          <material><ambient>0.0 0.0 0.8 1</ambient><diffuse>0.0 0.0 0.8 1</diffuse></material>
        </visual>

        <sensor name="camera" type="camera">
          <always_on>true</always_on>
          <update_rate>10</update_rate>
          <camera>
            <horizontal_fov>1.3962634</horizontal_fov>
            <image>
              <width>640</width>
              <height>480</height>
              <format>R8G8B8</format>
            </image>
            <clip>
              <near>0.02</near>
              <far>300</far>
            </clip>
            <noise>
              <type>gaussian</type>
              <mean>0.0</mean>
              <stddev>0.007</stddev>
            </noise>
          </camera>
          <topic>camera/image_raw</topic>
          <gz_frame_id>camera_link</gz_frame_id>
        </sensor>
      </link>

      <joint name="camera_joint" type="fixed">
        <parent>base_link</parent><child>camera_link</child>
      </joint>

      <!-- Differential drive -->
      <plugin filename="gz-sim-diff-drive-system" name="gz::sim::systems::DiffDrive">
        <left_joint>wheel_left_joint</left_joint>
        <right_joint>wheel_right_joint</right_joint>
        <wheel_separation>0.160</wheel_separation>
        <wheel_radius>0.033</wheel_radius>
        <odom_publish_frequency>20</odom_publish_frequency>
        <topic>cmd_vel</topic>
        <odom_topic>odom</odom_topic>
        <tf_topic>tf</tf_topic>
        <frame_id>odom</frame_id>
        <child_frame_id>base_footprint</child_frame_id>
        <min_acceleration>-1</min_acceleration>
        <max_acceleration>1</max_acceleration>
      </plugin>

      <!-- Joint state publisher -->
      <plugin filename="gz-sim-joint-state-publisher-system" name="gz::sim::systems::JointStatePublisher">
        <topic>joint_states</topic>
        <joint_name>wheel_left_joint</joint_name>
        <joint_name>wheel_right_joint</joint_name>
      </plugin>

    </model>

  </world>
</sdf>
```

---

## Notes

- **`maps/tb3_world.pgm` is a binary occupancy grid image** and cannot be embedded in this
  document. It must be copied separately from the source system:
  ```
  scp user@source:~/ros2-gazebo/src/tb3_sim/maps/tb3_world.pgm ./src/tb3_sim/maps/
  ```

- **`resource/tb3_sim`** is an empty ament resource marker file. Create it with:
  ```
  touch src/tb3_sim/resource/tb3_sim
  ```

- **The package is built inside the Docker image** during `docker compose build` — no manual
  `colcon build` is needed on the host. The `Dockerfile` runs colcon as part of the image
  build step.

- After creating all these files, proceed to `03-scripts.md`.
