#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live swap-window refresh ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-live-swap-window-refresh-$$"

SESSION="swap-refresh-live-$$"
CLIENT_PID=""

tmx() { tmux "$@"; }

cleanup() {
  if [ -n "$CLIENT_PID" ]; then
    kill "$CLIENT_PID" >/dev/null 2>&1 || true
  fi
  tmx kill-server >/dev/null 2>&1 || true
  tabby_cleanup_tmux_test_env
}
trap cleanup EXIT

if ! command -v script >/dev/null 2>&1; then
  echo "script(1) is required"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ] || [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

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
  tmx list-panes -a -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

sidebar_pane() {
  tmx list-panes -a -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null | \
    awk -F'|' '$2 ~ /(sidebar-renderer|sidebar)/ || $3 ~ /(sidebar-renderer|sidebar)/ {print $1; exit}'
}

sidebar_order_matches() {
  local pane
  pane="$(sidebar_pane)"
  [ -n "$pane" ] || return 1

  local content
  content="$(tmx capture-pane -p -t "$pane" -S -200 2>/dev/null || true)"
  [ -n "$content" ] || return 1

  local last_line=0
  local name
  for name in "$@"; do
    local line
    line="$(printf '%s\n' "$content" | grep -n "$name" | head -n 1 | cut -d: -f1)"
    [ -n "$line" ] || return 1
    if [ "$line" -le "$last_line" ]; then
      return 1
    fi
    last_line="$line"
  done
}

wait_for_sidebar_order() {
  local session_id="$1"
  shift
  local i
  for i in $(seq 1 80); do
    if sidebar_order_matches "$@"; then
      return 0
    fi
    "$PROJECT_ROOT/scripts/signal_sidebar.sh" "$session_id"
    sleep 0.2
  done
  return 1
}

current_window_name() {
  tmx display-message -p '#{window_name}'
}

start_attached_client() {
  local typescript="/tmp/tabby-live-swap-window-refresh-$$.typescript"
  local log_file="/tmp/tabby-live-swap-window-refresh-$$.log"
  TERM=xterm script -q -c "TERM=xterm '$TABBY_TMUX_REAL' -S '$TABBY_TEST_SOCKET_PATH' -f /dev/null attach-session -t '$SESSION'" "$typescript" >"$log_file" 2>&1 &
  CLIENT_PID=$!
  wait_for 40 bash -lc "'$TABBY_TMUX_REAL' -S '$TABBY_TEST_SOCKET_PATH' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "alpha"
tmx new-window -t "$SESSION:" -n "beta"
tmx new-window -t "$SESSION:" -n "gamma"
start_attached_client

tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx set-option -g @tabby_sidebar disabled
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full
tmx set-option -g @tabby_pane_headers off
tmx set-option -g @tabby_auto_rename off
tmx rename-window -t "$SESSION:0" "alpha"
tmx set-window-option -t "$SESSION:0" @tabby_name_locked 1
tmx rename-window -t "$SESSION:1" "beta"
tmx set-window-option -t "$SESSION:1" @tabby_name_locked 1
tmx rename-window -t "$SESSION:2" "gamma"
tmx set-window-option -t "$SESSION:2" @tabby_name_locked 1
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
sleep 1
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"

tmx select-window -t "$SESSION:1"
target_window_id="$(tmx display-message -p '#{window_id}')"
target_session_id="$(tmx display-message -p '#{session_id}')"
"$PROJECT_ROOT/scripts/signal_sidebar.sh" "$target_session_id"

if ! wait_for 40 session_has_sidebar; then
  echo "✗ session is missing sidebar renderer"
  exit 1
fi

if ! wait_for_sidebar_order "$target_session_id" alpha beta gamma; then
  echo "✗ initial sidebar order did not stabilize"
  pane="$(sidebar_pane)"
  [ -n "$pane" ] && tmx capture-pane -p -t "$pane" -S -200 || true
  exit 1
fi

"$PROJECT_ROOT/scripts/swap_window.sh" :+1 "$target_window_id" "$target_session_id"

if ! wait_for 30 bash -lc "[ \"\$(tmux display-message -p '#{window_name}')\" = 'beta' ]"; then
  echo "✗ focus did not stay on the original window after swap"
  echo "current=$(current_window_name)"
  exit 1
fi

if ! wait_for_sidebar_order "$target_session_id" alpha gamma beta; then
  echo "✗ sidebar order did not refresh after swap-window"
  pane="$(sidebar_pane)"
  [ -n "$pane" ] && tmx capture-pane -p -t "$pane" -S -200 || true
  exit 1
fi

echo "=== Live swap-window refresh test passed ==="
