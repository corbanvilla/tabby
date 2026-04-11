#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live pane-level bell via mock AI app ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux)"
if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-pane-bell-$$"
SOCKET_PATH=""
SESSION="live-pane-bell"
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
    frames: ["busy"]
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

seed_tabby_tmux_env() {
  SOCKET_PATH="$(tmx display-message -p '#{socket_path}')"
  tmx set-environment -g TABBY_TMUX_SOCKET "$SOCKET_PATH"
  tmx set-environment -g TABBY_TMUX_REAL "$tmux_real"
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
  local tty_dump="/tmp/tabby-live-pane-bell-tty-$$.typescript"
  local log_file="/tmp/tabby-live-pane-bell-client-$$.log"
  local tmux_cmd
  local attempt
  for attempt in 1 2 3; do
    [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" >/dev/null 2>&1 || true
    if tmx has-session -t "$SESSION" >/dev/null 2>&1; then
      tmux_cmd="TERM=xterm $tmux_real -L '$SOCKET' -f /dev/null attach-session -t '$SESSION'"
    else
      tmux_cmd="TERM=xterm $tmux_real -L '$SOCKET' -f /dev/null new-session -A -s '$SESSION' -n main 'exec bash -i'"
    fi
    HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_XDG" TERM=xterm \
      script -q -c "$tmux_cmd" "$tty_dump" >"$log_file" 2>&1 &
    CLIENT_PID=$!
    if wait_for 30 bash -lc "HOME='$TEST_HOME' XDG_CONFIG_HOME='$TEST_XDG' '$tmux_real' -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"; then
      return 0
    fi
    sleep 0.2
  done
  echo "failed to attach client"
  [ -f "$log_file" ] && sed -n '1,80p' "$log_file" || true
  return 1
}

pane_has_bell() {
  local pane="$1"
  [ "$(tmx display-message -p -t "$pane" '#{@tabby_bell}' 2>/dev/null || true)" = "1" ]
}

pane_no_bell() {
  local pane="$1"
  [ -z "$(tmx display-message -p -t "$pane" '#{@tabby_bell}' 2>/dev/null || true)" ]
}

tmx start-server
start_attached_client
wait_for 20 tmx has-session -t "$SESSION"
seed_tabby_tmux_env
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

CONTENT_PANE="$(tmx list-panes -t "$SESSION:0" -F "#{pane_id} #{pane_current_command} #{pane_active}" | awk '$2!="sidebar-renderer" && $3=="1"{print $1; exit}')"
tmx split-window -h -t "$CONTENT_PANE" 'exec bash -i'
sleep 1

LEFT_PANE="$(tmx list-panes -t "$SESSION:0" -F "#{pane_id} #{pane_left} #{pane_current_command}" | awk '$3!="sidebar-renderer"{print $0}' | sort -k2,2n | head -n1 | awk '{print $1}')"
RIGHT_PANE="$(tmx list-panes -t "$SESSION:0" -F "#{pane_id} #{pane_left} #{pane_current_command}" | awk '$3!="sidebar-renderer"{print $0}' | sort -k2,2n | tail -n1 | awk '{print $1}')"
if [ -z "$LEFT_PANE" ] || [ -z "$RIGHT_PANE" ] || [ "$LEFT_PANE" = "$RIGHT_PANE" ]; then
  echo "failed to identify two distinct content panes"
  tmx list-panes -t "$SESSION:0" -F "#{pane_id} left=#{pane_left} active=#{pane_active} cmd=#{pane_current_command}" || true
  exit 1
fi

tmx set-option -p -t "$LEFT_PANE" @tabby_pane_title left-ai
tmx set-option -p -t "$RIGHT_PANE" @tabby_pane_title right-ai

LEFT_READY="/tmp/tabby-left-ready-$$"
tmx send-keys -t "$LEFT_PANE" "MOCK_AI_WORK_DELAY=0.4 bash '$PROJECT_ROOT/tests/integration/mock_ai_ready_app.sh' left '$LEFT_READY'" C-m

if ! wait_for 40 pane_has_bell "$LEFT_PANE"; then
  echo "left pane did not receive pane-level bell"
  tmx display-message -p -t "$LEFT_PANE" '#{@tabby_bell}' || true
  exit 1
fi

if ! pane_no_bell "$RIGHT_PANE"; then
  echo "right pane unexpectedly received a bell"
  exit 1
fi

tmx select-pane -t "$LEFT_PANE"

if ! wait_for 30 pane_no_bell "$LEFT_PANE"; then
  echo "pane bell was not cleared on pane focus"
  tmx display-message -p -t "$LEFT_PANE" '#{@tabby_bell}' || true
  exit 1
fi

echo "=== Live pane-level bell test passed ==="
