#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Window kill focus matrix ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
TMUX_REAL="$(command -v tmux)"
SCENARIO_CLOSED="${1:-}"
SCENARIO_EXPECTED="${2:-}"
SCENARIO_LABEL="${3:-scenario}"

if [ -z "$TMUX_REAL" ]; then
  echo "tmux is required"
  exit 1
fi

if ! command -v script >/dev/null 2>&1; then
  echo "script(1) is required"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ] || [ ! -x "$PROJECT_ROOT/bin/new-window" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-window-kill-focus-$$"
SESSION="tabby-window-kill-focus"
CLIENT_PIDS=""
SESSION_ID=""

if [ -z "$SCENARIO_CLOSED" ] || [ -z "$SCENARIO_EXPECTED" ]; then
  echo "--- Scenario 1: closing active first window focuses next ---"
  bash "$0" 0 1 first
  echo "--- Scenario 2: closing active middle window focuses previous ---"
  bash "$0" 1 0 middle
  echo "--- Scenario 3: closing active last window focuses previous ---"
  bash "$0" 2 1 last
  echo "=== Window kill focus matrix test passed ==="
  exit 0
fi

tmx() {
  "$TMUX_REAL" -L "$SOCKET" -f /dev/null "$@"
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

seed_tabby_tmux_env() {
  local socket_path
  socket_path="$(tmx display-message -p '#{socket_path}')"
  tmx set-environment -g TABBY_TMUX_SOCKET "$socket_path"
  tmx set-environment -g TABBY_TMUX_REAL "$TMUX_REAL"
}

cleanup() {
  local pid_file watchdog_file pid
  for pid in $CLIENT_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  if [ -n "$SESSION_ID" ]; then
    pid_file="/tmp/tabby-daemon-${SESSION_ID}.pid"
    watchdog_file="/tmp/tabby-daemon-${SESSION_ID}.watchdog.pid"
    if [ -f "$pid_file" ]; then
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    fi
    if [ -f "$watchdog_file" ]; then
      pid="$(cat "$watchdog_file" 2>/dev/null || true)"
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "/tmp/tabby-daemon-${SESSION_ID}.pid" \
      "/tmp/tabby-daemon-${SESSION_ID}.sock" \
      "/tmp/tabby-daemon-${SESSION_ID}-events.log" \
      "/tmp/tabby-daemon-${SESSION_ID}.input.log" \
      "/tmp/tabby-daemon-${SESSION_ID}.clean-stop" \
      "/tmp/tabby-daemon-${SESSION_ID}.watchdog.pid"
  fi
  tmx kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

stop_clients() {
  for pid in $CLIENT_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  CLIENT_PIDS=""
}

start_attached_client() {
  local label="$1"
  local typescript="/tmp/tabby-window-kill-focus-${label}-$$.typescript"
  local log_file="/tmp/tabby-window-kill-focus-${label}-$$.log"
  TERM=xterm script -q -c "TERM=xterm $TMUX_REAL -L $SOCKET -f /dev/null attach-session -t $SESSION" "$typescript" >"$log_file" 2>&1 &
  local pid=$!
  CLIENT_PIDS="$CLIENT_PIDS $pid"
  if ! wait_for 30 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"; then
    echo "✗ failed to attach client for $SESSION"
    [ -f "$log_file" ] && sed -n '1,80p' "$log_file" || true
    exit 1
  fi
}

session_has_sidebar() {
  tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
    | grep -Eq "(sidebar-renderer|sidebar)"
}

window_has_only_system_panes() {
  local target="$1"
  local summary
  summary="$(tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}|#{pane_dead}" 2>/dev/null | awk -F'|' '
    $3 != "1" {
      if ($1 ~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ || $2 ~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/) {
        system_count++
      } else {
        main_count++
      }
    }
    END { printf "%d %d\n", system_count+0, main_count+0 }'
  )"
  [ -n "$summary" ] || return 1
  local system_count main_count
  system_count="$(printf '%s' "$summary" | awk '{print $1}')"
  main_count="$(printf '%s' "$summary" | awk '{print $2}')"
  [ "${system_count:-0}" -gt 0 ] && [ "${main_count:-0}" -eq 0 ]
}

no_orphan_windows() {
  local wid
  while IFS= read -r wid; do
    [ -z "$wid" ] && continue
    if window_has_only_system_panes "$wid"; then
      return 1
    fi
  done < <(tmx list-windows -t "$SESSION" -F "#{window_id}" 2>/dev/null || true)
  return 0
}

window_count_is() {
  local expected="$1"
  local count
  count="$(tmx list-windows -t "$SESSION" -F "#{window_id}" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" = "$expected" ]
}

window_missing_id() {
  local target="$1"
  ! tmx list-windows -t "$SESSION" -F "#{window_id}" 2>/dev/null | grep -qx "$target"
}

client_window_id() {
  tmx list-clients -F "#{session_name}|#{window_id}" 2>/dev/null | awk -F'|' -v s="$SESSION" '$1 == s { print $2; exit }'
}

client_window_is() {
  local expected="$1"
  [ "$(client_window_id)" = "$expected" ]
}

dump_state() {
  echo "--- clients ---"
  tmx list-clients -F "#{session_name}|#{client_tty}|#{window_id}|#{window_name}" 2>/dev/null || true
  echo "--- windows ---"
  tmx list-windows -t "$SESSION" -F "#{window_id}|#{window_index}|#{window_name}|#{window_active}|#{window_layout}" 2>/dev/null || true
  echo "--- panes ---"
  tmx list-panes -s -t "$SESSION" -F "#{window_id}|#{window_name}|#{pane_id}|#{pane_current_command}|#{pane_start_command}|#{pane_active}|#{pane_dead}" 2>/dev/null || true
}

enable_sidebar() {
  local attempt
  tmx set-option -g @tabby_sidebar_position left
  tmx set-option -g @tabby_sidebar_mode full
  tmx set-option -g @tabby_pane_headers off
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 50 session_has_sidebar; then
      return 0
    fi
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.4
  done
  echo "✗ sidebar failed to start"
  dump_state
  exit 1
}

reset_three_window_session() {
  local session_id
  stop_clients
  tmx kill-session -t "$SESSION" >/dev/null 2>&1 || true
  tmx new-session -d -s "$SESSION" -n "zero"
  tmx new-window -t "$SESSION:" -n "one"
  tmx new-window -t "$SESSION:" -n "two"
  session_id="$(tmx display-message -p -t "$SESSION:" '#{session_id}' 2>/dev/null || true)"
  SESSION_ID="$session_id"
  if [ -n "$session_id" ]; then
    rm -f "/tmp/tabby-daemon-${session_id}.pid" \
      "/tmp/tabby-daemon-${session_id}.sock" \
      "/tmp/tabby-daemon-${session_id}-events.log" \
      "/tmp/tabby-daemon-${session_id}.input.log" \
      "/tmp/tabby-daemon-${session_id}.clean-stop" \
      "/tmp/tabby-daemon-${session_id}.watchdog.pid"
  fi
  seed_tabby_tmux_env
  tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
  sleep 1
  start_attached_client "$SCENARIO_LABEL"
  enable_sidebar
}

assert_active_kill_focus() {
  local closed_index="$1"
  local expected_focus="$2"
  local closed_window_id expected_focus_id

  closed_window_id="$(tmx display-message -p -t "$SESSION:$closed_index" "#{window_id}" 2>/dev/null || true)"
  expected_focus_id="$(tmx display-message -p -t "$SESSION:$expected_focus" "#{window_id}" 2>/dev/null || true)"

  tmx select-window -t "$SESSION:$closed_index"
  if ! wait_for 30 client_window_is "$closed_window_id"; then
    echo "✗ failed to focus window $closed_index before killing it"
    dump_state
    exit 1
  fi

  tmx run-shell -b -t "$SESSION:$closed_index" "$PROJECT_ROOT/scripts/kill_window.sh $closed_index"

  if ! wait_for 50 window_count_is 2; then
    echo "✗ killing active window $closed_index did not reduce session to two windows"
    dump_state
    exit 1
  fi
  if ! wait_for 50 window_missing_id "$closed_window_id"; then
    echo "✗ killed window $closed_window_id still exists"
    dump_state
    exit 1
  fi
  if ! wait_for 50 client_window_is "$expected_focus_id"; then
    echo "✗ killing active window $closed_index focused the wrong window (expected $expected_focus)"
    dump_state
    exit 1
  fi
  if ! wait_for 50 no_orphan_windows; then
    echo "✗ killing active window $closed_index left a renderer-only orphan"
    dump_state
    exit 1
  fi

  echo "✓ killing active window $closed_index focused window $expected_focus without leaving an orphan"
}

reset_three_window_session
assert_active_kill_focus "$SCENARIO_CLOSED" "$SCENARIO_EXPECTED"
