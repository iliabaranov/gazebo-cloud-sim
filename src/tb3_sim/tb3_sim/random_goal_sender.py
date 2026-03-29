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
