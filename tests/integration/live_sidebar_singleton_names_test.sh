#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live sidebar singleton + names ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux)"
if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-names-$$"
SESSION="live-names"
CLIENT_PID=""

tmx() {
  "$tmux_real" -L "$SOCKET" -f /dev/null "$@"
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

cleanup() {
  if [ -n "$CLIENT_PID" ]; then
    kill "$CLIENT_PID" >/dev/null 2>&1 || true
  fi
  tmx kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

sidebar_count_ok() {
  local counts
  counts="$(tmx list-panes -a -F "#{window_id} #{pane_current_command}" 2>/dev/null | awk '$2=="sidebar-renderer"{c[$1]++} END{for (w in c) print c[w]}')"
  [ -n "$counts" ] || return 1
  if echo "$counts" | awk '$1 != 1 { exit 1 }'; then
    return 0
  fi
  return 1
}

sidebar_contains_names() {
  local content
  content="$(for p in $(tmx list-panes -a -F "#{pane_id} #{pane_current_command}" | awk '$2=="sidebar-renderer"{print $1}'); do
    tmx capture-pane -p -t "$p" -S -20
    printf '\n'
  done)"
  echo "$content" | grep -q "hello" && echo "$content" | grep -q "mywin"
}

start_attached_client() {
  local tty_dump="/tmp/tabby-live-names-tty-$$.typescript"
  local log_file="/tmp/tabby-live-names-client-$$.log"
  TERM=xterm script -q -c "TERM=xterm $tmux_real -L $SOCKET -f /dev/null attach-session -t $SESSION" "$tty_dump" >"$log_file" 2>&1 &
  CLIENT_PID=$!
  wait_for 30 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "main"
start_attached_client
tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

tmx set-option -g @tabby_sidebar disabled
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full
tmx set-option -g @tabby_pane_headers off
tmx set-option -g @tabby_auto_rename off
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
sleep 1
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"

tmx rename-window -t "$SESSION:0" "hello"
tmx set-window-option -t "$SESSION:0" @tabby_name_locked 1
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/signal_sidebar.sh"
tmx new-window -t "$SESSION:" -n "mywin" "sleep 60"
tmx set-window-option -t "$SESSION:1" @tabby_name_locked 1
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/signal_sidebar.sh"
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"

if ! wait_for 40 sidebar_count_ok; then
  echo "renderer singleton invariant failed"
  tmx list-panes -a -F "#{window_id} #{pane_id} #{pane_current_command} | #{pane_start_command}" || true
  exit 1
fi

PID_FILE="$(find /tmp -maxdepth 1 -name 'tabby-daemon-*.pid' | head -n1)"
if [ -n "$PID_FILE" ] && [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE")"
  for _ in $(seq 1 10); do
    kill -USR1 "$PID" 2>/dev/null || true
    sleep 0.2
  done
fi

if ! wait_for 30 sidebar_count_ok; then
  echo "renderer singleton invariant failed after refresh storm"
  tmx list-panes -a -F "#{window_id} #{pane_id} #{pane_current_command} | #{pane_start_command}" || true
  exit 1
fi

if ! wait_for 10 sidebar_contains_names; then
  echo "sidebar did not render manual names quickly enough"
  for p in $(tmx list-panes -a -F "#{pane_id} #{pane_current_command}" | awk '$2=="sidebar-renderer"{print $1}'); do
    echo "--- pane $p ---"
    tmx capture-pane -p -t "$p" -S -20 || true
  done
  exit 1
fi

echo "=== Live sidebar singleton + names test passed ==="
