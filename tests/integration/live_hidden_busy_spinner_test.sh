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
SOCKET_PATH="/tmp/tmux-$(id -u)/$SOCKET"
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
  env -u TMUX \
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="$TEST_XDG" \
    TABBY_TMUX_REAL="$tmux_real" \
    TABBY_TMUX_SOCKET="$SOCKET_PATH" \
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
  rm -rf "$TEST_HOME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_attached_client() {
  local tty_dump="/tmp/tabby-live-hidden-busy-tty-$$.typescript"
  local log_file="/tmp/tabby-live-hidden-busy-client-$$.log"
  env -u TMUX HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_XDG" TERM=xterm \
    TABBY_TMUX_REAL="$tmux_real" TABBY_TMUX_SOCKET="$SOCKET_PATH" \
    script -q -c "env -u TMUX TERM=xterm TABBY_TMUX_REAL='$tmux_real' TABBY_TMUX_SOCKET='$SOCKET_PATH' '$tmux_real' -L '$SOCKET' -f /dev/null attach-session -t '$SESSION'" "$tty_dump" >"$log_file" 2>&1 &
  CLIENT_PID=$!
  wait_for 30 bash -lc "HOME='$TEST_HOME' XDG_CONFIG_HOME='$TEST_XDG' '$tmux_real' -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"
}

window_has_sidebar() {
  tmx list-panes -t "$SESSION:0" -F "#{pane_current_command}" | grep -qx "sidebar-renderer"
}

sidebar_pane_for_window() {
  local window="$1"
  tmx list-panes -t "$window" -F "#{pane_id} #{pane_current_command}" | awk '$2=="sidebar-renderer"{print $1; exit}'
}

sidebar_capture() {
  local window="$1"
  local pane
  pane="$(sidebar_pane_for_window "$window")"
  [ -n "$pane" ] || return 1
  tmx capture-pane -p -t "$pane"
}

sidebar_capture_contains_busy() {
  local window="$1"
  local capture
  capture="$(sidebar_capture "$window" || true)"
  [[ "$capture" == *"A"* || "$capture" == *"B"* || "$capture" == *"C"* || "$capture" == *"D"* ]]
}

window_has_busy_or_bell() {
  local busy bell
  busy="$(tmx show-options -w -qv -t "$SESSION:0" @tabby_busy 2>/dev/null || true)"
  bell="$(tmx show-options -w -qv -t "$SESSION:0" @tabby_bell 2>/dev/null || true)"
  [ "$busy" = "1" ] || [ "$bell" = "1" ]
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "busy" 'exec bash -l'
tmx set-environment -gu TMUX 2>/dev/null || true
tmx set-environment -g TABBY_TMUX_REAL "$tmux_real"
tmx set-environment -g TABBY_TMUX_SOCKET "$SOCKET_PATH"
start_attached_client
tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

tmx set-option -g @tabby_sidebar disabled
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
SIDEBAR_PANE="$(sidebar_pane_for_window "$SESSION:0")"

if [ -z "$CONTENT_PANE" ] || [ -z "$SIDEBAR_PANE" ]; then
  echo "failed to identify busy window panes"
  tmx list-panes -t "$SESSION:0" -F "#{pane_id} cmd=#{pane_current_command} active=#{pane_active}" || true
  exit 1
fi

tmx set-window-option -t "$SESSION:0" @tabby_group Default

tmx new-window -t "$SESSION:" -n "other" 'exec bash -l'
tmx select-window -t "$SESSION:1"
tmx set-window-option -t "$SESSION:0" @tabby_bell 1
sleep 0.6

if ! wait_for 20 window_has_busy_or_bell; then
  echo "hidden busy window lost its inactive busy/bell indicator state"
  tmx show-options -w -t "$SESSION:0" | grep '@tabby_\\(busy\\|bell\\)' || true
  exit 1
fi

echo "=== Hidden busy spinner test passed ==="
