#!/usr/bin/env bash
set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINDOW_ID="${1:-}"

"$CURRENT_DIR/scripts/signal_sidebar.sh" "$WINDOW_ID" >/dev/null 2>&1 || true
"$CURRENT_DIR/scripts/refresh_status.sh" >/dev/null 2>&1 || true
