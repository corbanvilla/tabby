#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Window return acknowledges active input pane ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux)"
if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-input-return-$$"
SESSION="live-input-return"
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
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

start_attached_client() {
  local tty_dump="/tmp/tabby-live-input-return-tty-$$.typescript"
  local log_file="/tmp/tabby-live-input-return-client-$$.log"
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_XDG" TERM=xterm \
    script -q -c "TERM=xterm $tmux_real -L $SOCKET -f /dev/null attach-session -t $SESSION" "$tty_dump" >"$log_file" 2>&1 &
  CLIENT_PID=$!
  wait_for 30 bash -lc "HOME='$TEST_HOME' XDG_CONFIG_HOME='$TEST_XDG' '$tmux_real' -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"
}

sidebar_capture() {
  local window="$1"
  local pane
  pane="$(tmx list-panes -t "$window" -F "#{pane_id} #{pane_current_command}" | awk '$2=="sidebar-renderer"{print $1; exit}')"
  [ -n "$pane" ] || return 1
  tmx capture-pane -p -t "$pane"
}

capture_has_input() {
  sidebar_capture "$SESSION:1" | grep -q "INPUT"
}

capture_lacks_input() {
  ! sidebar_capture "$SESSION:1" | grep -q "INPUT"
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
[ -n "$AI_PANE" ] || { echo "failed to find ai pane"; exit 1; }

# Start a descendant codex-like process so the pane is recognized as AI, then
# drive the hook-level input state directly for a deterministic return-ack test.
tmx send-keys -t "$AI_PANE" "MOCK_AI_BUSY_SECS=1 MOCK_AI_IDLE_SECS=20 bash '$PROJECT_ROOT/tests/integration/mock_passive_ai.sh'" C-m
sleep 2
tmx set-window-option -t "$SESSION:0" @tabby_input 1

tmx select-window -t "$SESSION:1"
if ! wait_for 50 capture_has_input; then
  echo "input indicator never appeared before window return"
  sidebar_capture "$SESSION:1" || true
  exit 1
fi

tmx select-window -t "$SESSION:0"
if ! wait_for 20 capture_lacks_input; then
  echo "input indicator did not clear when returning to the active pane"
  sidebar_capture "$SESSION:1" || true
  exit 1
fi

echo "=== Window-return input ack test passed ==="
