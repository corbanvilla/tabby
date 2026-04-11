#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$CURRENT_DIR"

TARGET="${1:-}"
CURRENT_WINDOW_ID="${2:-$(tmux display-message -p '#{window_id}')}"
SESSION_ID="${3:-$(tmux display-message -p '#{session_id}')}"

if [ -z "$TARGET" ]; then
    echo "usage: swap_window.sh <target> [window_id] [session_id]" >&2
    exit 1
fi

tmux swap-window -t "$TARGET"

# Keep focus on the original window identity after the index swap.
if [ -n "$CURRENT_WINDOW_ID" ]; then
    tmux select-window -t "$CURRENT_WINDOW_ID" >/dev/null 2>&1 || true
fi

"$CURRENT_DIR/scripts/signal_sidebar.sh" "$SESSION_ID" >/dev/null 2>&1 || true
"$CURRENT_DIR/scripts/refresh_status.sh" >/dev/null 2>&1 || true
