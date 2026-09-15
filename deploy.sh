#!/usr/bin/env bash
# Everything inside the cluster (update-setup-01). Create the cluster first: cluster/cluster.sh up
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$SCRIPT_DIR/platformservices/deploy.sh"
"$SCRIPT_DIR/applications/deploy.sh"
