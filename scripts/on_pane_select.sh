#!/usr/bin/env bash
# Combined handler for pane selection - minimal for speed

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$CURRENT_DIR"
source "$CURRENT_DIR/scripts/_session_owner.sh"

# optimization: Accept session ID as arg to avoid tmux call overhead
SESSION_ID="$1"

if [ -z "$SESSION_ID" ]; then
    # Fallback for manual calls
    SESSION_ID=$(tmux display-message -p '#{session_id}')
fi
SESSION_ID="$(tabby_canonical_session_id "$SESSION_ID")"
[ -n "$SESSION_ID" ] || exit 0

# Skip during pane header spawning — the daemon is splitting panes to create
# 1-line header panes, which triggers after-select-pane hooks. Running the
# full handler during this window can cause stale pane data and style races.
SPAWNING=$(tmux show-option -gqv @tabby_spawning 2>/dev/null || echo "")
if [ "$SPAWNING" = "1" ]; then
    exit 0
fi

# A pane-level AI completion bell is acknowledged when that pane is focused.
tmux set-option -p -u @tabby_bell 2>/dev/null || true
# A pane-level AI input marker is acknowledged when that pane is focused.
# The daemon will keep it cleared until the tool becomes busy again.
tmux set-option -p @tabby_input_ack 1 2>/dev/null || true
tmux set-option -w -u @tabby_input 2>/dev/null || true

# Signal daemon to refresh immediately
RUNTIME_PREFIX="${TABBY_RUNTIME_PREFIX:-}"
DAEMON_PID_FILE="/tmp/${RUNTIME_PREFIX}tabby-daemon-${SESSION_ID}.pid"
if [ -f "$DAEMON_PID_FILE" ]; then
    read -r PID < "$DAEMON_PID_FILE"
    kill -USR1 "$PID" 2>/dev/null || true
fi

exit 0
