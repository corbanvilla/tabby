#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Passive AI input persists across window switches ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux)"
if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-passive-input-$$"
SESSION="live-passive-input"
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
busy_detection:
  ai_tools:
    - codex
  idle_timeout: 1
indicators:
  bell:
    enabled: true
    icon: "BELL"
    color: "#ffcc00"
  busy:
    enabled: true
    frames: ["BUSY"]
    color: "#00aaff"
  input:
    enabled: true
    icon: "INPUT"
    frames: ["INPUT"]
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
  local tty_dump="/tmp/tabby-live-passive-input-tty-$$.typescript"
  local log_file="/tmp/tabby-live-passive-input-client-$$.log"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_XDG" TERM=xterm \
    script -q -c "TERM=xterm $tmux_real -L $SOCKET -f /dev/null attach-session -t $SESSION" "$tty_dump" >"$log_file" 2>&1 &
  CLIENT_PID=$!
  wait_for 30 bash -lc "HOME='$TEST_HOME' XDG_CONFIG_HOME='$TEST_XDG' '$tmux_real' -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"
}

sidebar_capture() {
  local window="$1"
  local sidebar_pane
  sidebar_pane="$(tmx list-panes -t "$window" -F "#{pane_id} #{pane_current_command}" | awk '$2=="sidebar-renderer"{print $1; exit}')"
  [ -n "$sidebar_pane" ] || return 1
  tmx capture-pane -p -t "$sidebar_pane"
}

capture_has_busy() {
  sidebar_capture "$SESSION:1" | grep -q "BUSY"
}

capture_has_input() {
  sidebar_capture "$SESSION:1" | grep -q "INPUT"
}

capture_has_bell() {
  sidebar_capture "$SESSION:1" | grep -q "BELL"
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "aiwin" 'exec bash -l'
start_attached_client
tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

tmx set-option -g @tabby_sidebar enabled
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full
tmx set-option -g @tabby_pane_headers off
tmx set-option -g @tabby_auto_rename off
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
sleep 1
tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"

tmx new-window -t "$SESSION:" -n "fishwin" 'exec bash -l'
sleep 1
tmx select-window -t "$SESSION:0"

AI_PANE="$(tmx list-panes -t "$SESSION:0" -F "#{pane_id} #{pane_current_command} #{pane_active}" | awk '$2!="sidebar-renderer" && $3=="1"{print $1; exit}')"
if [ -z "$AI_PANE" ]; then
  echo "failed to find AI test pane"
  exit 1
fi

tmx send-keys -t "$AI_PANE" "MOCK_AI_BUSY_SECS=2 MOCK_AI_IDLE_SECS=6 bash '$PROJECT_ROOT/tests/integration/mock_passive_ai.sh'" C-m

tmx select-window -t "$SESSION:1"
sleep 1

if ! wait_for 40 capture_has_input; then
  echo "input indicator did not appear on inactive AI window"
  sidebar_capture "$SESSION:1" || true
  exit 1
fi

CAPTURE1="$(sidebar_capture "$SESSION:1" || true)"
sleep 1.5
CAPTURE2="$(sidebar_capture "$SESSION:1" || true)"

if [[ "$CAPTURE1" != *"INPUT"* || "$CAPTURE2" != *"INPUT"* ]]; then
  echo "input indicator did not persist while inactive"
  printf '%s\n%s\n' '--- capture1 ---' "$CAPTURE1"
  printf '%s\n%s\n' '--- capture2 ---' "$CAPTURE2"
  exit 1
fi

if capture_has_bell; then
  echo "unexpected bell indicator appeared during passive input state"
  sidebar_capture "$SESSION:1" || true
  exit 1
fi

echo "=== Passive AI input persistence test passed ==="
