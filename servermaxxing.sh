#!/usr/bin/env bash
set -euo pipefail

# Root shortcut wrapper for servermaxxing (scripts/servermaxxing.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/scripts/servermaxxing.sh" "$@"
