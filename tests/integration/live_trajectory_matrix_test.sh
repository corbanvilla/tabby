#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live trajectory matrix ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux)"

if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

SOCKET="tabby-live-traj-$$"
SESSION_MAIN="traj-main"
SESSION_ALT="traj-alt"
CLIENT_PIDS=""

tmx() {
  "$tmux_real" -L "$SOCKET" -f /dev/null "$@"
}

seed_tabby_tmux_env() {
  local socket_path
  socket_path="$(tmx display-message -p '#{socket_path}')"
  tmx set-environment -g TABBY_TMUX_SOCKET "$socket_path"
  tmx set-environment -g TABBY_TMUX_REAL "$tmux_real"
}

cleanup() {
  for pid in $CLIENT_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  tmx kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

assert_true() {
  local description="$1"
  shift
  if "$@"; then
    echo "✓ $description"
  else
    echo "✗ $description"
    exit 1
  fi
}

pane_contains() {
  local target="$1"
  local needle="$2"
  tmx capture-pane -t "$target" -p 2>/dev/null | grep -Fq "$needle"
}

content_pane_for_window() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
    | awk -F'|' '$2 !~ /(sidebar|sidebar-renderer|pane-header|tabby-daemon)/ && $3 !~ /(sidebar|sidebar-renderer|pane-header|tabby-daemon)/ {print $1; exit}'
}

session_has_sidebar() {
  local session="$1"
  tmx list-panes -s -t "$session" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

window_name_present() {
  local session="$1"
  local expected="$2"
  tmx list-windows -t "$session" -F "#{window_name}" 2>/dev/null | grep -qx "$expected"
}

enable_sidebar_for_session() {
  local session="$1"
  local attempt
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 50 session_has_sidebar "$session"; then
      return 0
    fi
    tmx run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.5
  done
  return 1
}

start_attached_client() {
  local session="$1"
  local label="$2"
  local tty_dump="/tmp/tabby-live-traj-${label}-tty-$$.typescript"
  local log_file="/tmp/tabby-live-traj-${label}-client-$$.log"
  TERM=xterm script -q -c "TERM=xterm $tmux_real -L $SOCKET -f /dev/null attach-session -t $session" "$tty_dump" >"$log_file" 2>&1 &
  local pid=$!
  CLIENT_PIDS="$CLIENT_PIDS $pid"
  wait_for 30 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$session'"
}

echo "Bootstrapping isolated tmux server..."
tmx start-server
tmx new-session -d -s "$SESSION_MAIN" -n "main"
seed_tabby_tmux_env
start_attached_client "$SESSION_MAIN" "main"
tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full
assert_true "sidebar enabled in main session" enable_sidebar_for_session "$SESSION_MAIN"

# Trajectory 1: write in main window.
main_pane="$(content_pane_for_window "$SESSION_MAIN:0")"
if [ -z "$main_pane" ]; then
  echo "✗ failed to locate main content pane"
  exit 1
fi
tmx send-keys -t "$main_pane" "echo TRAJ_01_MAIN_WRITE" Enter
sleep 0.2
assert_true "trajectory 1 main write visible" wait_for 20 pane_contains "$main_pane" "TRAJ_01_MAIN_WRITE"

# Trajectory 2: create new window and write there.
win2="$(tmx new-window -P -F "#{window_id}" -t "$SESSION_MAIN:" -n "traj-2")"
win2_pane="$(content_pane_for_window "$win2")"
if [ -z "$win2_pane" ]; then
  echo "✗ failed to locate win2 content pane"
  exit 1
fi
tmx send-keys -t "$win2_pane" "echo TRAJ_02_WIN2_WRITE" Enter
sleep 0.2
assert_true "trajectory 2 write visible in new window" wait_for 20 pane_contains "$win2_pane" "TRAJ_02_WIN2_WRITE"

# Trajectory 3: switch back and write again; verify both histories.
tmx select-window -t "$SESSION_MAIN:0"
main_pane="$(content_pane_for_window "$SESSION_MAIN:0")"
tmx send-keys -t "$main_pane" "echo TRAJ_03_MAIN_RETURN" Enter
sleep 0.2
assert_true "trajectory 3 main return write visible" wait_for 20 pane_contains "$main_pane" "TRAJ_03_MAIN_RETURN"
assert_true "trajectory 3 previous win2 write preserved" pane_contains "$win2_pane" "TRAJ_02_WIN2_WRITE"

# Trajectory 4: rename window and verify.
tmx rename-window -t "$win2" "traj-2-renamed"
assert_true "trajectory 4 rename reflected" wait_for 20 window_name_present "$SESSION_MAIN" "traj-2-renamed"

# Trajectory 5: split pane, write in new pane, and verify both panes.
base_main_pane="$(content_pane_for_window "$SESSION_MAIN:0")"
tmx split-window -t "$base_main_pane" -v -l 8
split_pane="$(tmx list-panes -t "$SESSION_MAIN:0" -F "#{pane_id}|#{pane_active}" | awk -F'|' '$2=="1"{print $1; exit}')"
main_pane="$(content_pane_for_window "$SESSION_MAIN:0")"
tmx send-keys -t "$split_pane" "echo TRAJ_05_PANE_SPLIT" Enter
sleep 0.2
assert_true "trajectory 5 split pane write visible" wait_for 20 pane_contains "$split_pane" "TRAJ_05_PANE_SPLIT"
tmx send-keys -t "$main_pane" "echo TRAJ_05_ORIG_PANE_STILL_OK" Enter
sleep 0.2
assert_true "trajectory 5 original pane still writable" wait_for 20 pane_contains "$main_pane" "TRAJ_05_ORIG_PANE_STILL_OK"

# Trajectory 6: kill split pane and continue in surviving pane.
tmx kill-pane -t "$split_pane"
main_pane="$(content_pane_for_window "$SESSION_MAIN:0")"
tmx send-keys -t "$main_pane" "echo TRAJ_06_AFTER_KILL_PANE" Enter
sleep 0.2
assert_true "trajectory 6 write after pane kill visible" wait_for 20 pane_contains "$main_pane" "TRAJ_06_AFTER_KILL_PANE"

# Trajectory 7: toggle sidebar off then on; confirm state recovers.
tmx run-shell -b -t "$SESSION_MAIN:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
sleep 0.8
assert_true "trajectory 7 sidebar disabled state set" bash -lc "[ \"\$(tmux -L '$SOCKET' -f /dev/null show-options -gqv @tabby_sidebar)\" = \"disabled\" ]"
tmx run-shell -b -t "$SESSION_MAIN:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
assert_true "trajectory 7 sidebar re-enabled" wait_for 50 session_has_sidebar "$SESSION_MAIN"

# Trajectory 8: create another window, write, switch back, and write again.
w8="$(tmx new-window -P -F "#{window_id}" -t "$SESSION_MAIN:" -n "traj-8")"
w8_pane="$(content_pane_for_window "$w8")"
tmx send-keys -t "$w8_pane" "echo TRAJ_08_NEW_WINDOW_WRITE" Enter
sleep 0.2
assert_true "trajectory 8 write in additional window visible" wait_for 20 pane_contains "$w8_pane" "TRAJ_08_NEW_WINDOW_WRITE"
tmx select-window -t "$SESSION_MAIN:0"
main_pane="$(content_pane_for_window "$SESSION_MAIN:0")"
tmx send-keys -t "$main_pane" "echo TRAJ_08_BACK_TO_MAIN_WRITE" Enter
sleep 0.2
assert_true "trajectory 8 write after switching back visible" wait_for 20 pane_contains "$main_pane" "TRAJ_08_BACK_TO_MAIN_WRITE"

# Trajectory 9: create alternate session, enable sidebar, write there.
tmx new-session -d -s "$SESSION_ALT" -n "alt-main"
start_attached_client "$SESSION_ALT" "alt"
assert_true "trajectory 9 sidebar enabled in alt session" enable_sidebar_for_session "$SESSION_ALT"
alt_pane="$(content_pane_for_window "$SESSION_ALT:0")"
tmx send-keys -t "$alt_pane" "echo TRAJ_09_ALT_SESSION_WRITE" Enter
sleep 0.2
assert_true "trajectory 9 alt session write visible" wait_for 20 pane_contains "$alt_pane" "TRAJ_09_ALT_SESSION_WRITE"
assert_true "trajectory 9 main session data still present" pane_contains "$main_pane" "TRAJ_08_BACK_TO_MAIN_WRITE"

# Trajectory 10: rapid cross-window writes and verification.
w3="$(tmx new-window -P -F "#{window_id}" -t "$SESSION_MAIN:" -n "traj-10")"
w3_pane="$(content_pane_for_window "$w3")"
for i in $(seq 1 6); do
  tmx select-window -t "$SESSION_MAIN:0"
  main_pane="$(content_pane_for_window "$SESSION_MAIN:0")"
  tmx send-keys -t "$main_pane" "echo TRAJ_10_MAIN_$i" Enter
  tmx select-window -t "$w3"
  w3_pane="$(content_pane_for_window "$w3")"
  tmx send-keys -t "$w3_pane" "echo TRAJ_10_W3_$i" Enter
done
sleep 0.4
assert_true "trajectory 10 final main write present" wait_for 20 pane_contains "$main_pane" "TRAJ_10_MAIN_6"
assert_true "trajectory 10 final w3 write present" wait_for 20 pane_contains "$w3_pane" "TRAJ_10_W3_6"

echo "=== Live trajectory matrix test passed (10 trajectories) ==="
