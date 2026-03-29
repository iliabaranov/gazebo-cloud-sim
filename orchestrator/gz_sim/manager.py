"""
SimulatorManager — all Docker interactions in one place.

Designed so that a future API layer (FastAPI, etc.) calls the same methods
as the CLI, with no shell-outs between them.
"""
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

import docker
import docker.errors
import docker.types

from .config import (
    IMAGE, CONTAINER_PREFIX, VOLUME_PREFIX,
    HTTP_BASE_PORT, VNC_BASE_PORT, FOXGLOVE_BASE_PORT, MAX_INSTANCES,
    GPU_DEVICES, CONTAINER_ENV,
    RTF_MEASURE_SECS, RESTART_DELAY_SECS,
)
from .models import Instance


# ── Helpers ────────────────────────────────────────────────────────────────────

def _detect_host_ip() -> str:
    """Prefer Tailscale IP; fall back to first global IPv4; then localhost."""
    for iface in ("tailscale0", None):
        cmd = ["ip", "-4", "addr", "show"]
        if iface:
            cmd.append(iface)
        else:
            cmd += ["scope", "global"]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True).stdout
            m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
            if m:
                return m.group(1)
        except Exception:
            pass
    return "localhost"


def _cpu_percent(stats: dict) -> Optional[float]:
    try:
        cpu  = stats["cpu_stats"]["cpu_usage"]["total_usage"]
        pcpu = stats["precpu_stats"]["cpu_usage"]["total_usage"]
        sys  = stats["cpu_stats"]["system_cpu_usage"]
        psys = stats["precpu_stats"]["system_cpu_usage"]
        ncpu = len(stats["cpu_stats"]["cpu_usage"].get("percpu_usage", [1]))
        delta_sys = sys - psys
        if delta_sys <= 0:
            return 0.0
        return round((cpu - pcpu) / delta_sys * ncpu * 100.0, 1)
    except (KeyError, ZeroDivisionError):
        return None


def _mem_mib(stats: dict) -> Optional[float]:
    try:
        return round(stats["memory_stats"]["usage"] / 1024 / 1024, 1)
    except KeyError:
        return None


# ── Manager ────────────────────────────────────────────────────────────────────

class SimulatorManager:
    def __init__(self):
        try:
            self.client = docker.from_env()
            self.client.ping()
        except docker.errors.DockerException as e:
            raise RuntimeError(
                f"Cannot connect to Docker daemon: {e}\n"
                "Is Docker running? Do you need 'sudo'?"
            ) from e
        self._host_ip = _detect_host_ip()

    # ── Inspection ─────────────────────────────────────────────────────────────

    def list_instances(self, *, include_stats: bool = False) -> list[Instance]:
        """Return all running gz_N containers, sorted by instance ID."""
        containers = self.client.containers.list(
            filters={"name": CONTAINER_PREFIX}
        )
        # Exact-match filter: gz_1, gz_2 ... not gz_something_else
        pattern = re.compile(rf"^/?{re.escape(CONTAINER_PREFIX)}\d+$")
        containers = [c for c in containers if pattern.match(c.name)]

        instances = []
        for c in containers:
            instances.append(self._to_instance(c, include_stats=include_stats))
        return sorted(instances, key=lambda i: i.id)

    def get_instance(self, instance_id: int) -> Instance:
        name = f"{CONTAINER_PREFIX}{instance_id}"
        try:
            c = self.client.containers.get(name)
        except docker.errors.NotFound:
            raise RuntimeError(f"Instance {instance_id} ({name}) not found.")
        return self._to_instance(c, include_stats=True)

    def _to_instance(self, container, *, include_stats: bool) -> Instance:
        name = container.name.lstrip("/")
        iid  = int(re.search(r"\d+$", name).group())

        cpu = mem = None
        if include_stats and container.status == "running":
            try:
                s = container.stats(stream=False)
                cpu = _cpu_percent(s)
                mem = _mem_mib(s)
            except Exception:
                pass

        return Instance(
            id             = iid,
            name           = name,
            container_id   = container.short_id,
            status         = container.status,
            http_port      = HTTP_BASE_PORT     + iid,
            vnc_port       = VNC_BASE_PORT      + iid,
            foxglove_port  = FOXGLOVE_BASE_PORT + iid,
            volume_name    = f"{VOLUME_PREFIX}{iid}",
            host_ip        = self._host_ip,
            cpu_percent    = cpu,
            mem_mib        = mem,
        )

    # ── RTF measurement ────────────────────────────────────────────────────────

    def get_rtf(self, instance_id: int) -> Optional[float]:
        """
        Subscribe to /stats inside the container for RTF_MEASURE_SECS and
        return the average realtime factor. Returns None on failure.
        """
        try:
            c = self.client.containers.get(f"{CONTAINER_PREFIX}{instance_id}")
        except docker.errors.NotFound:
            return None
        if c.status != "running":
            return None

        cmd = (
            f"GZ_PARTITION=sim_{instance_id} "
            f"timeout {RTF_MEASURE_SECS} ign topic -e -t /stats 2>/dev/null "
            f"| grep real_time_factor "
            f"| grep -oP '[-0-9.]+' "
            f"| awk '{{s+=$1;n++}} END{{if(n>0) printf \"%.4f\",s/n}}'"
        )
        result = c.exec_run(["bash", "-c", cmd], demux=False)
        output = (result.output or b"").decode().strip()
        try:
            return float(output)
        except ValueError:
            return None

    def get_rtf_parallel(self, instance_ids: list[int]) -> dict[int, Optional[float]]:
        """Measure RTF for multiple instances concurrently."""
        out: dict[int, Optional[float]] = {}
        with ThreadPoolExecutor(max_workers=min(len(instance_ids), 8)) as ex:
            futures = {ex.submit(self.get_rtf, iid): iid for iid in instance_ids}
            for f in as_completed(futures):
                iid = futures[f]
                try:
                    out[iid] = f.result()
                except Exception:
                    out[iid] = None
        return out

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    def start(self, count: int = 1) -> list[Instance]:
        """
        Start `count` new instances using the lowest available IDs.
        Raises RuntimeError if at or over MAX_INSTANCES.
        """
        running_ids = {i.id for i in self.list_instances()}
        available   = [n for n in range(1, MAX_INSTANCES + 1) if n not in running_ids]

        if not available:
            raise RuntimeError(f"Already at maximum capacity ({MAX_INSTANCES} instances).")

        slots = available[:count]
        if len(slots) < count:
            raise RuntimeError(
                f"Only {len(slots)} slot(s) free (max {MAX_INSTANCES}); requested {count}."
            )

        return [self._to_instance(self._run_container(iid), include_stats=False) for iid in slots]

    def stop(self, instance_id: int, *, timeout: int = 10) -> None:
        """
        Stop and remove the container. The named volume is preserved so
        data persists when the instance is started again.
        """
        name = f"{CONTAINER_PREFIX}{instance_id}"
        try:
            c = self.client.containers.get(name)
        except docker.errors.NotFound:
            raise RuntimeError(f"Instance {instance_id} is not running.")
        c.stop(timeout=timeout)
        c.remove()

    def stop_all(self, *, timeout: int = 10) -> list[int]:
        """Stop all running instances. Returns list of stopped IDs."""
        instances = self.list_instances()
        for inst in instances:
            self.stop(inst.id, timeout=timeout)
        return [i.id for i in instances]

    def scale(self, n: int) -> dict:
        """
        Bring total running instances to exactly n.
        Returns {"started": [Instance,...], "stopped": [int,...]}.
        """
        if not (0 <= n <= MAX_INSTANCES):
            raise ValueError(f"n must be 0–{MAX_INSTANCES}, got {n}.")

        running  = self.list_instances()
        current  = len(running)
        started  = []
        stopped  = []

        if n > current:
            started = self.start(n - current)
        elif n < current:
            # Stop highest-numbered instances first (lowest IDs run longest → most data)
            victims = sorted(running, key=lambda i: i.id, reverse=True)[: current - n]
            for inst in victims:
                self.stop(inst.id)
                stopped.append(inst.id)

        return {"started": started, "stopped": stopped}

    def restart(self, instance_id: int) -> Instance:
        """
        Stop a container and immediately restart it with the same volume.
        Used by the health monitor to recover an unhealthy instance.
        """
        self.stop(instance_id)
        time.sleep(RESTART_DELAY_SECS)
        c = self._run_container(instance_id)
        return self._to_instance(c, include_stats=False)

    def reset(self, instance_id: int) -> Instance:
        """
        Wipe the persistent volume and restart from image defaults.
        WARNING: destroys all user changes in this instance's volume.
        """
        # Stop container (ignore if not running)
        try:
            self.stop(instance_id)
        except RuntimeError:
            pass

        # Remove volume so the entrypoint re-seeds on next start
        vname = f"{VOLUME_PREFIX}{instance_id}"
        try:
            self.client.volumes.get(vname).remove(force=True)
        except docker.errors.NotFound:
            pass

        time.sleep(RESTART_DELAY_SECS)
        c = self._run_container(instance_id)
        return self._to_instance(c, include_stats=False)

    # ── Volume helpers ─────────────────────────────────────────────────────────

    def list_volumes(self) -> list[dict]:
        """List all gz_data_N volumes."""
        vols = self.client.volumes.list(filters={"name": VOLUME_PREFIX})
        result = []
        for v in vols:
            # Check if a container is currently using this volume
            iid   = re.search(r"\d+$", v.name)
            iid   = int(iid.group()) if iid else None
            cname = f"{CONTAINER_PREFIX}{iid}" if iid else None
            in_use = False
            if cname:
                try:
                    c = self.client.containers.get(cname)
                    in_use = c.status == "running"
                except docker.errors.NotFound:
                    pass
            result.append({
                "name":       v.name,
                "instance_id": iid,
                "in_use":     in_use,
                "mountpoint": v.attrs.get("Mountpoint", ""),
            })
        return sorted(result, key=lambda x: x.get("instance_id") or 0)

    # ── Internal ───────────────────────────────────────────────────────────────

    def _run_container(self, instance_id: int) -> "docker.models.containers.Container":
        name        = f"{CONTAINER_PREFIX}{instance_id}"
        volume_name = f"{VOLUME_PREFIX}{instance_id}"

        # Ensure the named volume exists (creates it if absent)
        try:
            self.client.volumes.get(volume_name)
        except docker.errors.NotFound:
            self.client.volumes.create(name=volume_name)

        # Remove any stopped container with this name so docker run succeeds
        try:
            self.client.containers.get(name).remove(force=True)
        except docker.errors.NotFound:
            pass

        env = {**CONTAINER_ENV, "ROS_DOMAIN_ID": str(instance_id)}

        return self.client.containers.run(
            IMAGE,
            command=["ros2", "launch", "tb3_sim", "tb3_nav2.launch.py"],
            name=name,
            detach=True,
            runtime="nvidia",
            environment=env,
            devices=GPU_DEVICES,
            ports={
                "8080/tcp": HTTP_BASE_PORT     + instance_id,
                "5900/tcp": VNC_BASE_PORT      + instance_id,
                "9090/tcp": FOXGLOVE_BASE_PORT + instance_id,   # rosbridge inside always :9090
            },
            volumes={
                volume_name: {"bind": "/instance_data", "mode": "rw"},
            },
        )
