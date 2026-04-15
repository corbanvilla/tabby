#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Sidebar refresh hooks ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGNAL_SCRIPT="$PROJECT_ROOT/scripts/signal_sidebar.sh"
RENAME_PANE_SCRIPT="$PROJECT_ROOT/scripts/rename_pane.sh"

export TABBY_TMUX_REAL="${TABBY_TMUX_REAL:-$(command -v tmux)}"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-sidebar-refresh"
source "$PROJECT_ROOT/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$PROJECT_ROOT"

TEST_SESSION="tabby-sidebar-refresh"
SIGNAL_DIR="$(mktemp -d /tmp/tabby-sidebar-refresh.XXXXXX)"
SIGNAL_LOG="$SIGNAL_DIR/signals.log"
LISTENER_SCRIPT="$SIGNAL_DIR/listener.sh"
FAKE_RESURRECT_DIR="$SIGNAL_DIR/tmux-resurrect"
SAVE_ARGS_FILE="$SIGNAL_DIR/save-args.log"
LISTENER_PID=""

cleanup() {
    [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" >/dev/null 2>&1 || true
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    tabby_cleanup_tmux_test_env
    rm -rf "$SIGNAL_DIR"
}
trap cleanup EXIT

start_listener() {
    [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" >/dev/null 2>&1 || true
    : > "$SIGNAL_LOG"
    "$LISTENER_SCRIPT" &
    LISTENER_PID="$!"
    printf '%s\n' "$LISTENER_PID" > "$PID_FILE"
}

wait_for() {
    local tries="$1"
    shift
    local cmd=("$@")
    local i
    for i in $(seq 1 "$tries"); do
        if "${cmd[@]}"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

signal_count_at_least() {
    local expected="$1"
    [ -f "$SIGNAL_LOG" ] || return 1
    [ "$(wc -l < "$SIGNAL_LOG" | tr -d ' ')" -ge "$expected" ]
}

tmux new-session -d -s "$TEST_SESSION" -n main
bash "$PROJECT_ROOT/tabby.tmux"

SESSION_ID="$(tmux display-message -p -t "$TEST_SESSION:" '#{session_id}')"
WINDOW_ID="$(tmux display-message -p -t "$TEST_SESSION:0" '#{window_id}')"
PANE_ID="$(tmux display-message -p -t "$TEST_SESSION:0.0" '#{pane_id}')"
PID_FILE="/tmp/${TABBY_RUNTIME_PREFIX:-}tabby-daemon-${SESSION_ID}.pid"

cat > "$LISTENER_SCRIPT" <<EOF
#!/usr/bin/env bash
trap 'printf "%s\n" "\$(date +%s%N)" >> "$SIGNAL_LOG"' USR1
while :; do
    sleep 1
done
EOF
chmod +x "$LISTENER_SCRIPT"

start_listener

bash "$SIGNAL_SCRIPT" "$SESSION_ID"
if wait_for 30 signal_count_at_least 1; then
    echo "✓ signal_sidebar targets socket-prefixed daemon pid files"
else
    echo "✗ signal_sidebar did not reach socket-prefixed daemon pid file"
    exit 1
fi

start_listener
bash "$SIGNAL_SCRIPT" "$WINDOW_ID"
if wait_for 60 signal_count_at_least 1; then
    echo "✓ signal_sidebar resolves session ids from window targets"
else
    echo "✗ signal_sidebar did not resolve a session id from the window target"
    exit 1
fi

start_listener
bash "$RENAME_PANE_SCRIPT" "$PANE_ID" "focus-pane"
if [ "$(tmux show-options -pv -t "$PANE_ID" @tabby_pane_title 2>/dev/null || true)" = "focus-pane" ] && \
   wait_for 60 signal_count_at_least 1; then
    echo "✓ rename_pane updates pane title and signals a sidebar refresh"
else
    echo "✗ rename_pane did not update pane title or refresh signal"
    exit 1
fi

if tmux show-hooks -g after-rename-window | grep -q "on_window_renamed.sh" && \
   tmux show-hooks -g pane-title-changed | grep -q "signal_sidebar"; then
    echo "✓ rename hooks trigger sidebar refresh for window and pane title changes"
else
    echo "✗ rename hooks are missing sidebar refresh wiring"
    tmux show-hooks -g after-rename-window || true
    tmux show-hooks -g pane-title-changed || true
    exit 1
fi

mkdir -p "$FAKE_RESURRECT_DIR/scripts" "$FAKE_RESURRECT_DIR/save_command_strategies"
cat > "$FAKE_RESURRECT_DIR/scripts/save.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$SAVE_ARGS_FILE"
EOF
chmod +x "$FAKE_RESURRECT_DIR/scripts/save.sh"

TABBY_TMUX_RESURRECT_DIR="$FAKE_RESURRECT_DIR" bash "$PROJECT_ROOT/scripts/resurrect_save.sh" quiet
if [ "$(cat "$SAVE_ARGS_FILE" 2>/dev/null || true)" = "quiet" ]; then
    echo "✓ resurrect save wrapper supports quiet saves"
else
    echo "✗ resurrect save wrapper did not forward quiet mode"
    cat "$SAVE_ARGS_FILE" 2>/dev/null || true
    exit 1
fi

echo "=== Sidebar refresh hooks test passed ==="
