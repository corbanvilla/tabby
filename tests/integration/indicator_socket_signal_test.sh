#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Indicator Socket Signal ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-indicator-signal"

TEST_SESSION="tabby-indicator-signal-test"
SIGNAL_FILE="$(mktemp /tmp/tabby-indicator-signal.XXXXXX)"
rm -f "$SIGNAL_FILE"

cleanup() {
  if [ -n "${TRAP_PID:-}" ]; then
    kill "$TRAP_PID" 2>/dev/null || true
  fi
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  rm -f "$SIGNAL_FILE" "${PID_FILE:-}" "${LEGACY_PID_FILE:-}"
  tabby_cleanup_tmux_test_env
}
trap cleanup EXIT

tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
tmux new-session -d -s "$TEST_SESSION" -n "main"
SESSION_ID="$(tmux display-message -p -t "$TEST_SESSION" '#{session_id}')"
SOCKET_PATH="$(tmux display-message -p -t "$TEST_SESSION" '#{socket_path}')"

source "$PROJECT_ROOT/scripts/_tmux_socket_env.sh"
RUNTIME_PREFIX="$(tabby_runtime_prefix_for_socket "$SOCKET_PATH")"
PID_FILE="/tmp/${RUNTIME_PREFIX}tabby-daemon-${SESSION_ID}.pid"
LEGACY_PID_FILE="/tmp/tabby-daemon-${SESSION_ID}.pid"
rm -f "$PID_FILE" "$LEGACY_PID_FILE"

bash -c "trap 'touch \"$SIGNAL_FILE\"' USR1; while :; do sleep 1; done" &
TRAP_PID="$!"
printf '%s\n' "$TRAP_PID" > "$PID_FILE"

TABBY_TMUX_SOCKET="$SOCKET_PATH" "$PROJECT_ROOT/scripts/set-tabby-indicator.sh" busy 1

for _ in $(seq 1 30); do
  if [ -f "$SIGNAL_FILE" ]; then
    echo "✓ set-tabby-indicator signaled the socket-prefixed daemon pid"
    exit 0
  fi
  sleep 0.1
done

echo "✗ set-tabby-indicator did not signal the socket-prefixed daemon pid" >&2
echo "socket=$SOCKET_PATH session=$SESSION_ID pid_file=$PID_FILE trap_pid=$TRAP_PID" >&2
exit 1
