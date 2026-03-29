#!/usr/bin/env bash
# stop.sh — Stop and remove all gz_ simulation containers.
#
# Usage:
#   bash scripts/stop.sh          # stop all gz_* containers
#   bash scripts/stop.sh gz_1     # stop a specific container

set -euo pipefail

if [[ $# -gt 0 ]]; then
    CONTAINERS=("$@")
else
    mapfile -t CONTAINERS < <(sudo docker ps -a --filter "name=gz_" --format "{{.Names}}")
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo "No gz_ containers found."
    exit 0
fi

echo "Stopping ${#CONTAINERS[@]} container(s): ${CONTAINERS[*]}"

for name in "${CONTAINERS[@]}"; do
    sudo docker stop "$name" &>/dev/null && echo "  stopped: $name" || true
    sudo docker rm   "$name" &>/dev/null && echo "  removed: $name" || true
done

echo "Done."
