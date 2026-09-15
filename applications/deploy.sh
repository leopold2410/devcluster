#!/usr/bin/env bash
# Default test applications (update-setup-01). Others are deployed from their own folder.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$SCRIPT_DIR/testapp/deploy.sh"
