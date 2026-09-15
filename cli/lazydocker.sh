#!/usr/bin/env bash
# Start lazydocker in a container (update-setup-01).
# Usage: cli/lazydocker.sh [project-dir]   (default: current directory)
# The project directory is the working directory: if it contains a Compose file,
# lazydocker shows that project's services. Its git repository (or the directory
# itself) is mounted read-only at the same path, so "docker compose" commands see
# the same paths as on the host and relative symlinks (cli/.env -> ../versions.env) resolve.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "${1:-$PWD}" && pwd)
MOUNT_DIR=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")

HOST_UID=$(id -u)
HOST_GID=$(id -g)
DOCKER_GID=$(stat -c %g /var/run/docker.sock)
export HOST_UID HOST_GID DOCKER_GID
exec docker compose -f "$SCRIPT_DIR/compose.yaml" run --rm \
    -v "$MOUNT_DIR:$MOUNT_DIR:ro" -w "$PROJECT_DIR" lazydocker
