#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)"
INDICATOR="$SCRIPT_DIR/set-tabby-indicator.sh"

# Best-effort Tabby completion signal for Codex notify events.
if [ -x "$INDICATOR" ]; then
    "$INDICATOR" busy 0 >/dev/null 2>&1 || true
    "$INDICATOR" input 0 >/dev/null 2>&1 || true
    "$INDICATOR" bell 1 >/dev/null 2>&1 || true
fi

# Optional chained hook. If the first arg is an executable/script path, run it
# with the remaining args so existing notify workflows keep working.
if [ "$#" -gt 0 ] && [ -n "${1:-}" ] && [ -f "$1" ]; then
    target="$1"
    shift
    exec bash "$target" "$@"
fi

exit 0
