#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live tmux sessions ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"

tmux_real="$(command -v tmux)"
if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
  echo "Building binaries..."
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET_A="tabby-live-a-$$"
SOCKET_B="tabby-live-b-$$"
SESSION_A="live-a"
SESSION_A2="live-a-2"
SESSION_B="live-b"
CLIENT_PIDS=""

tmx() {
  local socket="$1"
  shift
  "$tmux_real" -L "$socket" -f /dev/null "$@"
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
    sleep 0.2
  done
  return 1
}

session_has_sidebar() {
  local socket="$1"
  local session="$2"
  tmx "$socket" list-panes -s -t "$session" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
    | grep -Eq "(sidebar-renderer|sidebar)"
}

window_has_sidebar() {
  local socket="$1"
  local target="$2"
  tmx "$socket" list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
    | grep -Eq "(sidebar-renderer|sidebar)"
}

enable_sidebar_for_window() {
  local socket="$1"
  local session="$2"
  local window_target="$3"
  local attempt
  for attempt in 1 2 3; do
    if wait_for 40 window_has_sidebar "$socket" "$window_target"; then
      return 0
    fi
    tmx "$socket" run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.4
  done
  return 1
}

enable_sidebar_for_session() {
  local socket="$1"
  local session="$2"
  local attempt
  for attempt in 1 2 3; do
    tmx "$socket" set-option -g @tabby_sidebar disabled
    tmx "$socket" run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 40 session_has_sidebar "$socket" "$session"; then
      return 0
    fi
    tmx "$socket" run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.5
  done
  return 1
}

cleanup() {
  for pid in $CLIENT_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  tmx "$SOCKET_A" kill-server >/dev/null 2>&1 || true
  tmx "$SOCKET_B" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_attached_client() {
  local socket="$1"
  local session="$2"
  local label="$3"
  local tty_dump="/tmp/tabby-live-${label}-tty-$$.typescript"
  local log_file="/tmp/tabby-live-${label}-client-$$.log"
  TERM=xterm script -q -c "TERM=xterm $tmux_real -L $socket -f /dev/null attach-session -t $session" "$tty_dump" >"$log_file" 2>&1 &
  local pid=$!
  CLIENT_PIDS="$CLIENT_PIDS $pid"
  wait_for 30 tmx "$socket" has-session -t "$session" >/dev/null 2>&1 || true
  if ! wait_for 30 bash -lc "tmux -L '$socket' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$session'"; then
    echo "✗ failed to attach client for $session on socket $socket"
    [ -f "$log_file" ] && sed -n '1,80p' "$log_file" || true
    exit 1
  fi
}

echo "Starting isolated tmux server A ($SOCKET_A)"
tmx "$SOCKET_A" start-server
tmx "$SOCKET_A" new-session -d -s "$SESSION_A" -n "main"
start_attached_client "$SOCKET_A" "$SESSION_A" "server-a-main"
tmx "$SOCKET_A" run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx "$SOCKET_A" set-option -g @tabby_sidebar_position left
tmx "$SOCKET_A" set-option -g @tabby_sidebar_mode full

if enable_sidebar_for_session "$SOCKET_A" "$SESSION_A"; then
  echo "✓ sidebar renderer started in $SESSION_A"
else
  echo "✗ sidebar renderer did not start in $SESSION_A"
  tmx "$SOCKET_A" list-panes -s -F "#{session_name}|#{window_name}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
  exit 1
fi

before_count="$(tmx "$SOCKET_A" list-windows -t "$SESSION_A" | wc -l | tr -d ' ')"
new_window_id="$(tmx "$SOCKET_A" new-window -P -F "#{window_id}" -t "$SESSION_A:" -n "new-live-window")"
after_count="$(tmx "$SOCKET_A" list-windows -t "$SESSION_A" | wc -l | tr -d ' ')"

if [ "$after_count" -eq $((before_count + 1)) ]; then
  echo "✓ new window created in $SESSION_A"
else
  echo "✗ new window count mismatch: before=$before_count after=$after_count"
  exit 1
fi

if enable_sidebar_for_window "$SOCKET_A" "$SESSION_A" "$new_window_id"; then
  echo "✓ sidebar renderer attached to new window"
else
  echo "✗ sidebar renderer missing from new window"
  tmx "$SOCKET_A" list-panes -t "$new_window_id" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
  exit 1
fi

tmx "$SOCKET_A" rename-window -t "$new_window_id" "renamed-live-window"
if tmx "$SOCKET_A" list-windows -t "$SESSION_A" -F "#{window_name}" | grep -qx "renamed-live-window"; then
  echo "✓ window rename reflected in live session"
else
  echo "✗ renamed window not found"
  tmx "$SOCKET_A" list-windows -t "$SESSION_A" -F "#{window_index}:#{window_name}" || true
  exit 1
fi

tmx "$SOCKET_A" new-session -d -s "$SESSION_A2" -n "second-session-main"
start_attached_client "$SOCKET_A" "$SESSION_A2" "server-a-second"
if enable_sidebar_for_session "$SOCKET_A" "$SESSION_A2"; then
  echo "✓ second session on same server received renderer"
else
  echo "✗ second session on same server did not receive renderer"
  tmx "$SOCKET_A" list-panes -s -F "#{session_name}|#{window_name}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
  exit 1
fi

echo "Starting isolated tmux server B ($SOCKET_B)"
tmx "$SOCKET_B" start-server
tmx "$SOCKET_B" new-session -d -s "$SESSION_B" -n "other-main"
start_attached_client "$SOCKET_B" "$SESSION_B" "server-b-main"
tmx "$SOCKET_B" run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx "$SOCKET_B" set-option -g @tabby_sidebar_position left
tmx "$SOCKET_B" set-option -g @tabby_sidebar_mode full

if enable_sidebar_for_session "$SOCKET_B" "$SESSION_B"; then
  echo "✓ independent server B received renderer"
else
  echo "✗ server B renderer did not start"
  tmx "$SOCKET_B" list-panes -s -F "#{session_name}|#{window_name}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
  exit 1
fi

# Ensure server A state remains intact after server B bootstrap.
if session_has_sidebar "$SOCKET_A" "$SESSION_A" && session_has_sidebar "$SOCKET_A" "$SESSION_A2"; then
  echo "✓ server A sessions remained healthy after server B startup"
else
  echo "✗ server A lost sidebar state after server B startup"
  tmx "$SOCKET_A" list-panes -s -F "#{session_name}|#{window_name}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
  exit 1
fi

echo "=== Live tmux sessions test passed ==="
