# Orchestrator: gz-sim CLI and Health Monitor

Python-based container orchestrator that wraps the Docker SDK with a clean domain model. `gz_sim/` is the library package; `gz-sim` is the CLI entry point (installed to `PATH` by `install.sh`); `health-monitor` (installed as `gz-sim-health`) is the realtime-factor daemon that automatically restarts degraded instances. A future API layer would import `SimulatorManager` from `gz_sim/manager.py` directly — no duplication with the CLI.

---

## `orchestrator/requirements.txt`

Python package dependencies (used as fallback if apt packages are unavailable).

```
docker>=7.0.0
click>=8.1.0
rich>=13.0.0
```

---

## `orchestrator/gz_sim/__init__.py`

Package marker (empty — all public symbols are imported from submodules directly).

```python
```

---

## `orchestrator/gz_sim/config.py`

Central configuration for the orchestrator. Every value has a sensible default and can be overridden with an environment variable, making it straightforward to adapt to a different image, port layout, or VM size without touching code.

```python
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
HTTP_BASE_PORT      = 8079   # noVNC:       gz_1 → 8080,  gz_2 → 8081, ...
VNC_BASE_PORT       = 5899   # raw VNC:     gz_1 → 5900,  gz_2 → 5901, ...
FOXGLOVE_BASE_PORT  = 9089   # rosbridge:   gz_1 → 9090,  gz_2 → 9091, ...

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
```

---

## `orchestrator/gz_sim/models.py`

Data model for a simulation instance. The `novnc_url`, `foxglove_url`, and `is_running` properties keep display logic out of the manager and CLI.

```python
from dataclasses import dataclass
from typing import Optional


@dataclass
class Instance:
    id:             int
    name:           str
    container_id:   str
    status:         str            # 'running', 'exited', 'created', ...
    http_port:      int
    vnc_port:       int
    foxglove_port:  int
    volume_name:    str
    host_ip:        str
    cpu_percent:    Optional[float] = None   # None when stopped or not yet sampled
    mem_mib:        Optional[float] = None

    @property
    def novnc_url(self) -> str:
        return (
            f"http://{self.host_ip}:{self.http_port}"
            f"/vnc.html?autoconnect=true&resize=scale"
        )

    @property
    def foxglove_url(self) -> str:
        return f"ws://{self.host_ip}:{self.foxglove_port}"

    @property
    def is_running(self) -> bool:
        return self.status == "running"
```

---

## `orchestrator/gz_sim/manager.py`

All Docker interactions in one place. The `SimulatorManager` class is the single source of truth for container lifecycle, RTF measurement, scaling, and volume management. Both the CLI and the health monitor call it directly — there are no shell-outs between them.

Key design points:
- `list_instances()` filters strictly to `gz_N` names, ignoring `gz_cap_*` capacity-test containers.
- `get_rtf_parallel()` uses a `ThreadPoolExecutor` so measuring N instances takes only as long as one measurement, not N×6 seconds.
- `scale(n)` stops the highest-numbered instances first, preserving the longest-running ones.
- `reset()` removes the named volume so the container entrypoint re-seeds from image defaults on the next start.

```python
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
                "9090/tcp": FOXGLOVE_BASE_PORT + instance_id,
            },
            volumes={
                volume_name: {"bind": "/instance_data", "mode": "rw"},
            },
        )
```

---

## `orchestrator/gz-sim`

CLI entry point. Built on Click + Rich. Commands: `status`, `start`, `stop`, `scale`, `restart`, `reset`, `logs`, `shell`, `volumes`. Each command is a thin wrapper around the corresponding `SimulatorManager` method.

```python
#!/usr/bin/env python3
"""
gz-sim — CLI for managing ROS2 Gazebo simulation containers.

Commands:
  status          Show all running instances (CPU, memory, URLs)
  start  [--n N]  Spin up N more instances  (default: 1)
  stop   <id|all> Stop one or all instances  (volume preserved)
  scale  <N>      Set total running count to exactly N
  restart <id>    Stop and restart one instance (preserves volume)
  reset   <id>    Wipe instance volume and restart from image defaults
  logs    <id>    Stream logs from an instance
  shell   <id>    Open a bash shell inside an instance
  volumes         List all persistent data volumes
"""

import os
import sys
import subprocess

# Allow running from any directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import click
from rich.console import Console
from rich.table import Table
from rich.text import Text
from rich import box

from gz_sim.manager import SimulatorManager
from gz_sim.config import MAX_INSTANCES, CONTAINER_PREFIX

console = Console()


def _manager() -> SimulatorManager:
    try:
        return SimulatorManager()
    except RuntimeError as e:
        console.print(f"[red]Error:[/red] {e}")
        sys.exit(1)


def _status_indicator(status: str) -> Text:
    if status == "running":
        return Text("● running", style="green")
    elif status in ("exited", "dead"):
        return Text("○ stopped", style="red")
    else:
        return Text(f"◌ {status}", style="yellow")


# ── CLI group ──────────────────────────────────────────────────────────────────

@click.group()
def cli():
    """gz-sim — ROS2 Gazebo simulation container orchestrator."""


# ── status ─────────────────────────────────────────────────────────────────────

@cli.command()
@click.option("--rtf", is_flag=True, default=False,
              help="Also measure realtime factor (~6s per instance, run in parallel).")
def status(rtf):
    """Show all running instances with CPU, memory, and noVNC URLs."""
    mgr       = _manager()
    instances = mgr.list_instances(include_stats=True)
    running   = sum(1 for i in instances if i.is_running)

    console.print()
    console.print(
        f"  [bold]gz-sim[/bold]  ·  "
        f"[green]{running}[/green] / [white]{MAX_INSTANCES}[/white] instances running"
    )
    console.print()

    if not instances:
        console.print("  [dim]No instances running. Use [bold]gz-sim start[/bold] to launch one.[/dim]")
        console.print()
        return

    # Optional parallel RTF measurement
    rtf_values: dict[int, object] = {}
    if rtf and instances:
        console.print("  [dim]Measuring realtime factors…[/dim]")
        rtf_values = mgr.get_rtf_parallel([i.id for i in instances if i.is_running])
        console.print()

    t = Table(box=box.SIMPLE_HEAD, show_edge=False, pad_edge=True)
    t.add_column("ID",       style="bold", justify="right", width=4)
    t.add_column("Name",     style="cyan")
    t.add_column("Status",   no_wrap=True)
    t.add_column("CPU",      justify="right")
    t.add_column("Memory",   justify="right")
    if rtf:
        t.add_column("RTF",  justify="right")
    t.add_column("noVNC URL")
    t.add_column("Foxglove URL")
    t.add_column("Volume",   style="dim")

    for inst in instances:
        cpu_str = f"{inst.cpu_percent:.1f}%" if inst.cpu_percent is not None else "—"
        mem_str = f"{inst.mem_mib:.0f} MiB"  if inst.mem_mib     is not None else "—"

        rtf_str = ""
        if rtf:
            r = rtf_values.get(inst.id)
            if r is None:
                rtf_str = "[dim]N/A[/dim]"
            elif r < 0.90:
                rtf_str = f"[red]{r:.3f}[/red]"
            elif r < 0.97:
                rtf_str = f"[yellow]{r:.3f}[/yellow]"
            else:
                rtf_str = f"[green]{r:.3f}[/green]"

        row = [
            str(inst.id),
            inst.name,
            _status_indicator(inst.status),
            cpu_str,
            mem_str,
        ]
        if rtf:
            row.append(rtf_str)
        row += [inst.novnc_url, inst.foxglove_url, inst.volume_name]
        t.add_row(*row)

    console.print(t)


# ── start ──────────────────────────────────────────────────────────────────────

@cli.command()
@click.option("--n", "count", default=1, show_default=True,
              help="Number of instances to start.")
def start(count):
    """Spin up N new simulation instances (uses lowest available IDs)."""
    mgr = _manager()
    running = len(mgr.list_instances())

    if running >= MAX_INSTANCES:
        console.print(
            f"[red]Already at maximum capacity ({MAX_INSTANCES} instances).[/red]"
        )
        sys.exit(1)

    headroom = MAX_INSTANCES - running
    if count > headroom:
        console.print(
            f"[yellow]Requested {count} but only {headroom} slot(s) free. "
            f"Starting {headroom}.[/yellow]"
        )
        count = headroom

    console.print(f"\n  Starting [bold]{count}[/bold] instance(s)…\n")
    try:
        started = mgr.start(count)
    except RuntimeError as e:
        console.print(f"[red]Error:[/red] {e}")
        sys.exit(1)

    for inst in started:
        console.print(f"  [green]✓[/green]  [bold]{inst.name}[/bold]"
                      f"  (volume: {inst.volume_name})")
        console.print(f"       noVNC:     {inst.novnc_url}")
        console.print(f"       Foxglove:  {inst.foxglove_url}")

    console.print()
    console.print("  [dim]NAV2 takes ~30 s to initialise before the robot moves.[/dim]")
    console.print()


# ── stop ───────────────────────────────────────────────────────────────────────

@cli.command()
@click.argument("instance_id")
def stop(instance_id):
    """
    Stop an instance (container removed, volume preserved).

    Use 'all' to stop every running instance.
    """
    mgr = _manager()

    if instance_id.lower() == "all":
        instances = mgr.list_instances()
        if not instances:
            console.print("[dim]No instances running.[/dim]")
            return
        console.print(f"\n  Stopping [bold]{len(instances)}[/bold] instance(s)…\n")
        stopped = mgr.stop_all()
        for iid in stopped:
            console.print(f"  [green]✓[/green]  gz_{iid} stopped")
        console.print()
        return

    try:
        iid = int(instance_id)
    except ValueError:
        console.print(f"[red]Invalid instance ID: '{instance_id}'. "
                      "Use a number or 'all'.[/red]")
        sys.exit(1)

    console.print(f"\n  Stopping [bold]gz_{iid}[/bold]…")
    try:
        mgr.stop(iid)
        console.print(f"  [green]✓[/green]  gz_{iid} stopped (volume gz_data_{iid} preserved)\n")
    except RuntimeError as e:
        console.print(f"[red]Error:[/red] {e}")
        sys.exit(1)


# ── scale ──────────────────────────────────────────────────────────────────────

@cli.command()
@click.argument("n", type=int)
def scale(n):
    """Set total running instances to exactly N (starts or stops as needed)."""
    mgr     = _manager()
    current = len(mgr.list_instances())

    if n == current:
        console.print(f"\n  Already at {n} instance(s). Nothing to do.\n")
        return

    direction = "up" if n > current else "down"
    console.print(
        f"\n  Scaling [bold]{direction}[/bold]: "
        f"{current} → [bold]{n}[/bold] instances…\n"
    )

    try:
        result = mgr.scale(n)
    except (ValueError, RuntimeError) as e:
        console.print(f"[red]Error:[/red] {e}")
        sys.exit(1)

    for inst in result["started"]:
        console.print(f"  [green]✓[/green]  started [bold]{inst.name}[/bold]"
                      f"  noVNC: {inst.novnc_url}  Foxglove: {inst.foxglove_url}")
    for iid in result["stopped"]:
        console.print(f"  [red]✓[/red]  stopped gz_{iid}")

    console.print()


# ── restart ────────────────────────────────────────────────────────────────────

@cli.command()
@click.argument("instance_id", type=int)
def restart(instance_id):
    """Stop and restart an instance, keeping its persistent volume intact."""
    mgr = _manager()
    console.print(f"\n  Restarting [bold]gz_{instance_id}[/bold]…")
    try:
        inst = mgr.restart(instance_id)
        console.print(f"  [green]✓[/green]  {inst.name} restarted")
        console.print(f"       noVNC:     {inst.novnc_url}")
        console.print(f"       Foxglove:  {inst.foxglove_url}\n")
    except RuntimeError as e:
        console.print(f"[red]Error:[/red] {e}")
        sys.exit(1)


# ── reset ──────────────────────────────────────────────────────────────────────

@cli.command()
@click.argument("instance_id", type=int)
@click.option("--yes", is_flag=True, default=False,
              help="Skip the confirmation prompt.")
def reset(instance_id, yes):
    """
    Wipe an instance's persistent volume and restart from image defaults.

    WARNING: this permanently destroys any custom worlds, URDFs, or params
    you have saved to this instance.
    """
    if not yes:
        click.confirm(
            f"\n  This will permanently delete all data in volume gz_data_{instance_id}.\n"
            f"  Continue?",
            abort=True,
        )

    mgr = _manager()
    console.print(f"\n  Resetting [bold]gz_{instance_id}[/bold]…")
    try:
        inst = mgr.reset(instance_id)
        console.print(f"  [green]✓[/green]  {inst.name} reset and restarted with image defaults")
        console.print(f"       noVNC:     {inst.novnc_url}")
        console.print(f"       Foxglove:  {inst.foxglove_url}\n")
    except RuntimeError as e:
        console.print(f"[red]Error:[/red] {e}")
        sys.exit(1)


# ── logs ───────────────────────────────────────────────────────────────────────

@cli.command()
@click.argument("instance_id", type=int)
@click.option("--tail", default=50, show_default=True, help="Lines of history to show.")
def logs(instance_id, tail):
    """Stream logs from an instance (Ctrl-C to stop)."""
    container = f"{CONTAINER_PREFIX}{instance_id}"
    os.execvp("docker", ["docker", "logs", "-f", f"--tail={tail}", container])


# ── shell ──────────────────────────────────────────────────────────────────────

@cli.command()
@click.argument("instance_id", type=int)
def shell(instance_id):
    """Open an interactive bash shell inside an instance."""
    container = f"{CONTAINER_PREFIX}{instance_id}"
    # Source ROS2 environment automatically for convenience
    cmd = (
        "bash --rcfile <(echo '. /opt/ros/humble/setup.bash; "
        ". /ros2_ws/install/setup.bash 2>/dev/null; "
        "export GZ_PARTITION=sim_{id}')"
    ).format(id=instance_id)
    os.execvp("docker", ["docker", "exec", "-it", container, "bash", "-c", cmd])


# ── volumes ────────────────────────────────────────────────────────────────────

@cli.command()
def volumes():
    """List all persistent data volumes for simulation instances."""
    mgr  = _manager()
    vols = mgr.list_volumes()

    console.print()
    if not vols:
        console.print("  [dim]No gz_data_ volumes found.[/dim]\n")
        return

    t = Table(box=box.SIMPLE_HEAD, show_edge=False, pad_edge=True)
    t.add_column("Volume",      style="cyan")
    t.add_column("Instance ID", justify="center")
    t.add_column("In use",      justify="center")
    t.add_column("Mountpoint",  style="dim")

    for v in vols:
        in_use = "[green]yes[/green]" if v["in_use"] else "[dim]no[/dim]"
        t.add_row(
            v["name"],
            str(v["instance_id"]) if v["instance_id"] else "?",
            in_use,
            v["mountpoint"],
        )

    console.print(t)


if __name__ == "__main__":
    cli()
```

---

## `orchestrator/health-monitor`

RTF daemon. Polls all running `gz_N` containers in parallel every 30 seconds (configurable). Tracks consecutive rounds below the RTF threshold per instance and issues a `manager.restart()` after the configured number of failures. Measurement failures (e.g. a container still initialising) are not counted as health failures. Handles `SIGTERM` and `SIGINT` cleanly for use with `nohup` or a systemd unit.

```python
#!/usr/bin/env python3
"""
health-monitor — Poll realtime factor for all running gz_ containers
and restart any that are persistently unhealthy.

What "unhealthy" means:
  RTF < GZ_RTF_THRESHOLD (default 0.80) for GZ_RTF_FAILURES (default 3)
  consecutive measurement rounds.

Run in the foreground (logs to stdout):
  python3 orchestrator/health-monitor

Run in the background with log file:
  nohup python3 orchestrator/health-monitor >> /var/log/gz-health.log 2>&1 &
  echo $! > /var/run/gz-health.pid

Stop a background run:
  kill $(cat /var/run/gz-health.pid)
"""

import os
import sys
import signal
import logging
import time
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gz_sim.manager import SimulatorManager
from gz_sim.config import (
    RTF_THRESHOLD,
    RTF_POLL_INTERVAL,
    RTF_FAILURES_TO_RESTART,
    RTF_MEASURE_SECS,
)

# ── Logging ────────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("health-monitor")


# ── Signal handling ────────────────────────────────────────────────────────────

_shutdown = False

def _handle_signal(sig, _frame):
    global _shutdown
    log.info(f"Received signal {sig}, shutting down…")
    _shutdown = True

signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT,  _handle_signal)


# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    log.info("=" * 60)
    log.info("gz-sim health monitor starting")
    log.info(f"  RTF threshold:    {RTF_THRESHOLD}")
    log.info(f"  Measure window:   {RTF_MEASURE_SECS}s per instance")
    log.info(f"  Poll interval:    {RTF_POLL_INTERVAL}s between rounds")
    log.info(f"  Failures→restart: {RTF_FAILURES_TO_RESTART} consecutive")
    log.info("=" * 60)

    try:
        mgr = SimulatorManager()
    except RuntimeError as e:
        log.error(f"Cannot connect to Docker: {e}")
        sys.exit(1)

    # failure_counts[instance_id] = consecutive rounds below threshold
    failure_counts: dict[int, int] = defaultdict(int)
    total_restarts = 0
    round_num = 0

    while not _shutdown:
        round_num += 1
        instances = mgr.list_instances()
        running   = [i for i in instances if i.is_running]

        if not running:
            log.info(f"[round {round_num}] No instances running.")
        else:
            log.info(
                f"[round {round_num}] Checking {len(running)} instance(s) "
                f"(~{RTF_MEASURE_SECS}s per instance, parallel)…"
            )

            rtf_map = mgr.get_rtf_parallel([i.id for i in running])

            for inst in running:
                rtf = rtf_map.get(inst.id)

                if rtf is None:
                    # Measurement failed — container may still be starting up
                    log.warning(
                        f"  {inst.name}: RTF measurement failed "
                        f"(starting up, or /stats not yet published)"
                    )
                    # Don't count a measurement failure as a health failure
                    continue

                if rtf < RTF_THRESHOLD:
                    failure_counts[inst.id] += 1
                    log.warning(
                        f"  {inst.name}: RTF={rtf:.4f}  [BELOW {RTF_THRESHOLD}]  "
                        f"({failure_counts[inst.id]}/{RTF_FAILURES_TO_RESTART} consecutive)"
                    )

                    if failure_counts[inst.id] >= RTF_FAILURES_TO_RESTART:
                        log.error(
                            f"  {inst.name}: restarting after "
                            f"{failure_counts[inst.id]} unhealthy rounds"
                        )
                        try:
                            mgr.restart(inst.id)
                            total_restarts += 1
                            failure_counts[inst.id] = 0
                            log.info(f"  {inst.name}: restart complete")
                        except Exception as exc:
                            log.error(f"  {inst.name}: restart failed — {exc}")
                else:
                    if failure_counts[inst.id] > 0:
                        log.info(
                            f"  {inst.name}: RTF={rtf:.4f}  [recovered]  "
                            f"(resetting failure count)"
                        )
                        failure_counts[inst.id] = 0
                    else:
                        log.info(f"  {inst.name}: RTF={rtf:.4f}  OK")

        # Clean up failure counts for instances that no longer exist
        running_ids = {i.id for i in running}
        stale = [iid for iid in failure_counts if iid not in running_ids]
        for iid in stale:
            del failure_counts[iid]

        log.info(
            f"[round {round_num}] Done. "
            f"Total restarts this session: {total_restarts}. "
            f"Sleeping {RTF_POLL_INTERVAL}s…"
        )

        # Sleep in short increments so SIGTERM is handled promptly
        for _ in range(RTF_POLL_INTERVAL):
            if _shutdown:
                break
            time.sleep(1)

    log.info(
        f"Health monitor stopped. "
        f"Total restarts performed: {total_restarts}"
    )


if __name__ == "__main__":
    main()
```

---

## `orchestrator/install.sh`

Installs Python dependencies (preferring `apt` packages over pip on Ubuntu 22.04/24.04) and symlinks `gz-sim` and `health-monitor` into `/usr/local/bin` (or `~/bin` if not writable without sudo).

```bash
#!/usr/bin/env bash
# install.sh — Install gz-sim CLI and health-monitor.
#
# Usage:
#   bash orchestrator/install.sh
#
# What it does:
#   1. Installs Python dependencies (docker, click, rich) via pip
#   2. Symlinks gz-sim and health-monitor into /usr/local/bin
#      (or ~/bin if /usr/local/bin is not writable without sudo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GZ_SIM="${SCRIPT_DIR}/gz-sim"
HEALTH_MON="${SCRIPT_DIR}/health-monitor"

echo "=== gz-sim orchestrator install ==="
echo ""

# ── Python deps ───────────────────────────────────────────────────────────────
echo "Installing Python dependencies..."

# On Ubuntu 22.04/24.04 the system Python is externally managed.
# Prefer apt packages; fall back to pip with --break-system-packages.
APT_PKGS=(python3-docker python3-click python3-rich)
MISSING=()
for pkg in "${APT_PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "  Installing via apt: ${MISSING[*]}"
    apt-get install -y "${MISSING[@]}" 2>/dev/null \
        || python3 -m pip install --break-system-packages --quiet \
               -r "${SCRIPT_DIR}/requirements.txt"
else
    echo "  apt packages already present."
fi

python3 -c "import docker, click, rich" \
    || { echo "ERROR: Python deps missing after install attempt."; exit 1; }
echo "  docker, click, rich — OK."
echo ""

# ── Make scripts executable ───────────────────────────────────────────────────
chmod +x "$GZ_SIM" "$HEALTH_MON"

# ── Symlink to PATH ───────────────────────────────────────────────────────────
if [ -w /usr/local/bin ]; then
    BIN_DIR="/usr/local/bin"
else
    BIN_DIR="$HOME/bin"
    mkdir -p "$BIN_DIR"
    # Remind user to add ~/bin to PATH if not already there
    if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
        echo "  NOTE: Add ~/bin to your PATH:"
        echo "    echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
        echo ""
    fi
fi

ln -sf "$GZ_SIM"     "${BIN_DIR}/gz-sim"
ln -sf "$HEALTH_MON" "${BIN_DIR}/gz-sim-health"

echo "Installed:"
echo "  gz-sim        → ${BIN_DIR}/gz-sim"
echo "  gz-sim-health → ${BIN_DIR}/gz-sim-health"
echo ""
echo "Quick start:"
echo "  gz-sim status"
echo "  gz-sim start --n 3"
echo "  gz-sim --help"
echo ""
echo "Health monitor (run in background):"
echo "  nohup gz-sim-health >> /tmp/gz-health.log 2>&1 &"
echo "  echo \$! > /tmp/gz-health.pid"
echo "  tail -f /tmp/gz-health.log"
```

---

## Reconstruction

To reconstruct the `orchestrator/` tree from scratch:

1. Create the directories:
   ```bash
   mkdir -p orchestrator/gz_sim
   ```

2. Place files at the correct paths:
   - `orchestrator/requirements.txt`
   - `orchestrator/gz_sim/__init__.py`
   - `orchestrator/gz_sim/config.py`
   - `orchestrator/gz_sim/models.py`
   - `orchestrator/gz_sim/manager.py`
   - `orchestrator/gz-sim`
   - `orchestrator/health-monitor`
   - `orchestrator/install.sh`

3. Make the entry points and installer executable:
   ```bash
   chmod +x orchestrator/gz-sim orchestrator/health-monitor orchestrator/install.sh
   ```

4. Run the installer (installs Python deps and symlinks to PATH):
   ```bash
   sudo bash orchestrator/install.sh
   ```

5. Confirm the install:
   ```bash
   gz-sim --help
   ```

---

## Future API Extension

Because all logic lives in `SimulatorManager`, a REST API layer requires no duplication — it simply imports the same class the CLI uses:

```python
# In a FastAPI app:
from gz_sim.manager import SimulatorManager
mgr = SimulatorManager()

@app.get("/instances")
def list_instances():
    return [vars(i) for i in mgr.list_instances(include_stats=True)]

@app.post("/instances/start")
def start(n: int = 1):
    return [vars(i) for i in mgr.start(n)]
```

The CLI and API share the same manager — no duplication. Adding endpoints for `stop`, `scale`, `restart`, `reset`, and `volumes` follows the same one-liner pattern.
