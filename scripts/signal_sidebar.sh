#!/usr/bin/env bash
# Signal daemon to refresh window list (instant re-render + spawn new renderers)
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$CURRENT_DIR"

SESSION_ID="${1:-$(tmux display-message -p '#{session_id}')}"
PID_FILE="/tmp/tabby-daemon-${SESSION_ID}.pid"

if [ -f "$PID_FILE" ]; then
    kill -USR1 "$(cat "$PID_FILE")" 2>/dev/null || true
fi
