#!/usr/bin/env bash
# Signal daemon to refresh window list (instant re-render + spawn new renderers)
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$CURRENT_DIR"

TARGET_ID="${1:-}"
SESSION_ID=""

if [ -n "$TARGET_ID" ]; then
    case "$TARGET_ID" in
        \$*)
            SESSION_ID="$TARGET_ID"
            ;;
        @*)
            SESSION_ID="$(tmux list-windows -a -F '#{window_id}|#{session_id}' 2>/dev/null | awk -F'|' -v target="$TARGET_ID" '$1 == target { print $2; exit }')"
            ;;
        %*)
            SESSION_ID="$(tmux display-message -p -t "$TARGET_ID" '#{session_id}' 2>/dev/null || echo "")"
            ;;
        *)
            SESSION_ID="$(tmux display-message -p -t "$TARGET_ID" '#{session_id}' 2>/dev/null || echo "")"
            ;;
    esac
fi

if [ -z "$SESSION_ID" ]; then
    SESSION_ID="$(tmux display-message -p '#{session_id}' 2>/dev/null || echo "")"
fi

[ -n "$SESSION_ID" ] || exit 0
RUNTIME_PREFIX="${TABBY_RUNTIME_PREFIX:-}"
PID_FILE="/tmp/${RUNTIME_PREFIX}tabby-daemon-${SESSION_ID}.pid"

if [ -f "$PID_FILE" ]; then
    kill -USR1 "$(cat "$PID_FILE")" 2>/dev/null || true
fi
