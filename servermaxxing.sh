#!/usr/bin/env bash
set -euo pipefail

# Root shortcut wrapper for servermaxxing (scripts/servermaxxing.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/scripts/servermaxxing.sh" ]; then
    exec bash "${SCRIPT_DIR}/scripts/servermaxxing.sh" "$@"
else
    # Fallback when curled directly without local repo clone
    TMP_SCRIPT="$(mktemp /tmp/servermaxxing.XXXXXX.sh)"
    curl -fsSL https://raw.githubusercontent.com/kshanxs/servermaxxing/main/scripts/servermaxxing.sh -o "$TMP_SCRIPT"
    exec bash "$TMP_SCRIPT" "$@"
fi
