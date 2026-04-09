#!/usr/bin/env bash
# Combined handler for pane selection - minimal for speed

# optimization: Accept session ID as arg to avoid tmux call overhead
SESSION_ID="$1"

if [ -z "$SESSION_ID" ]; then
    # Fallback for manual calls
    SESSION_ID=$(tmux display-message -p '#{session_id}')
fi

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

# Signal daemon to refresh immediately
DAEMON_PID_FILE="/tmp/tabby-daemon-${SESSION_ID}.pid"
if [ -f "$DAEMON_PID_FILE" ]; then
    read -r PID < "$DAEMON_PID_FILE"
    kill -USR1 "$PID" 2>/dev/null || true
fi

exit 0
