#!/usr/bin/env bash
set -euo pipefail

# Root shortcut wrapper for scripts/tune-server.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/scripts/tune-server.sh" "$@"
