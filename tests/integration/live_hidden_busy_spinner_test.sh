#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Hidden busy window spinner keeps updating ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux)"
if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-hidden-busy-$$"
SESSION="live-hidden-busy"
CLIENT_PID=""
TEST_HOME="$(mktemp -d)"
TEST_XDG="$TEST_HOME/.config"
mkdir -p "$TEST_XDG/tabby"
cat >"$TEST_XDG/tabby/config.yaml" <<'YAML'
theme: default
widgets:
  clock:
    enabled: false
  stats:
    enabled: false
  pet:
    enabled: false
indicators:
  bell:
    enabled: true
    icon: "BELL"
    color: "#ffcc00"
  busy:
    enabled: true
    frames: ["A", "B", "C", "D"]
    color: "#00aaff"
  input:
    enabled: true
    icon: "?"
    frames: ["?"]
    color: "#ff00aa"
YAML

tmx() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_XDG" "$tmux_real" -L "$SOCKET" -f /dev/null "$@"
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
  rm -rf "$TEST_HOME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_attached_client() {
  local tty_dump="/tmp/tabby-live-hidden-busy-tty-$$.typescript"
  local log_file="/tmp/tabby-live-hidden-busy-client-$$.log"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_XDG" TERM=xterm \
    script -q -c "TERM=xterm $tmux_real -L $SOCKET -f /dev/null attach-session -t $SESSION" "$tty_dump" >"$log_file" 2>&1 &
  CLIENT_PID=$!
  wait_for 30 bash -lc "HOME='$TEST_HOME' XDG_CONFIG_HOME='$TEST_XDG' '$tmux_real' -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"
}

window_has_sidebar() {
  tmx list-panes -t "$SESSION:0" -F "#{pane_current_command}" | grep -qx "sidebar-renderer"
}

sidebar_capture_contains_busy() {
  local pane="$1"
  local capture
  capture="$(tmx capture-pane -p -t "$pane" || true)"
  [[ "$capture" == *"A"* || "$capture" == *"B"* || "$capture" == *"C"* || "$capture" == *"D"* ]]
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "busy" 'exec bash -l'
start_attached_client
tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

tmx set-option -g @tabby_sidebar enabled
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full
tmx set-option -g @tabby_pane_headers off
tmx set-option -g @tabby_auto_rename off
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
  if wait_for 5 window_has_sidebar; then
    break
  fi
done
if ! window_has_sidebar; then
  echo "sidebar renderer did not appear in busy window"
  tmx list-panes -t "$SESSION:0" -F "#{pane_id} cmd=#{pane_current_command} active=#{pane_active}" || true
  exit 1
fi

CONTENT_PANE="$(tmx list-panes -t "$SESSION:0" -F "#{pane_id} #{pane_current_command} #{pane_active}" | awk '$2!="sidebar-renderer" && $3=="1"{print $1; exit}')"
SIDEBAR_PANE="$(tmx list-panes -t "$SESSION:0" -F "#{pane_id} #{pane_current_command}" | awk '$2=="sidebar-renderer"{print $1; exit}')"

if [ -z "$CONTENT_PANE" ] || [ -z "$SIDEBAR_PANE" ]; then
  echo "failed to identify busy window panes"
  tmx list-panes -t "$SESSION:0" -F "#{pane_id} cmd=#{pane_current_command} active=#{pane_active}" || true
  exit 1
fi

tmx set-window-option -t "$SESSION:0" @tabby_group Default
tmx send-keys -t "$CONTENT_PANE" "MOCK_AI_WORK_DELAY=4 bash '$PROJECT_ROOT/tests/integration/mock_ai_ready_app.sh' hidden-spinner" C-m

if ! wait_for 40 sidebar_capture_contains_busy "$SIDEBAR_PANE"; then
  echo "busy indicator never appeared in sidebar"
  tmx capture-pane -p -t "$SIDEBAR_PANE" || true
  exit 1
fi

tmx new-window -t "$SESSION:" -n "other" 'exec bash -l'
tmx select-window -t "$SESSION:1"
sleep 0.6

CAPTURE1="$(tmx capture-pane -p -t "$SIDEBAR_PANE" || true)"
CAPTURE2="$CAPTURE1"
for _ in 1 2 3 4 5; do
  sleep 0.7
  CAPTURE2="$(tmx capture-pane -p -t "$SIDEBAR_PANE" || true)"
  if [ "$CAPTURE1" != "$CAPTURE2" ]; then
    break
  fi
done

if [ "$CAPTURE1" = "$CAPTURE2" ]; then
  echo "hidden busy window sidebar did not change while inactive"
  printf '%s\n%s\n' '--- capture1 ---' "$CAPTURE1"
  printf '%s\n%s\n' '--- capture2 ---' "$CAPTURE2"
  exit 1
fi

echo "=== Hidden busy spinner test passed ==="
