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
