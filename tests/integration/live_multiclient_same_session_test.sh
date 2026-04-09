#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live multi-client routing ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
TMUX_REAL="$(command -v tmux)"

if [ -z "$TMUX_REAL" ]; then
  echo "tmux is required"
  exit 1
fi

if ! command -v script >/dev/null 2>&1; then
  echo "script(1) is required"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/new-window" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ] || [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-multiclient-$$"
SESSION_A="multi-client-a"
SESSION_B="multi-client-b"
WRAPPER_DIR="$(mktemp -d /tmp/tabby-live-multiclient-tmux.XXXXXX)"
CLIENT_PIDS=""

cat > "$WRAPPER_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_REAL" -L "$SOCKET" -f /dev/null "\$@"
EOF
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

tmx() { command tmux "$@"; }

window_for_client_tty() {
  local tty="$1"
  tmx list-clients -F "#{client_tty}|#{window_id}" | awk -F'|' -v t="$tty" '$1==t{print $2; exit}'
}

cleanup() {
  for pid in $CLIENT_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  tmx kill-server >/dev/null 2>&1 || true
  rm -rf "$WRAPPER_DIR" >/dev/null 2>&1 || true
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

session_has_sidebar() {
  local session="$1"
  tmx list-panes -s -t "$session" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

window_has_sidebar() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

enable_sidebar_for_session() {
  local session="$1"
  local attempt
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 40 session_has_sidebar "$session"; then
      return 0
    fi
    tmx run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.4
  done
  return 1
}

start_client() {
  local session="$1"
  local label="$2"
  local typescript="/tmp/tabby-live-multiclient-${label}-$$.typescript"
  local log_file="/tmp/tabby-live-multiclient-${label}-$$.log"
  TERM=xterm script -q -c "TERM=xterm tmux attach-session -t '$session'" "$typescript" >"$log_file" 2>&1 &
  CLIENT_PIDS="$CLIENT_PIDS $!"
}

tmx start-server
tmx new-session -d -s "$SESSION_A" -n "main"
tmx new-window -t "$SESSION_A:" -n "other"
tmx new-session -d -s "$SESSION_B" -n "main"
start_client "$SESSION_A" "a"
start_client "$SESSION_B" "b"

if ! wait_for 40 bash -lc "[ \"\$(tmux -L '$SOCKET' -f /dev/null list-clients | wc -l | tr -d ' ')\" = '2' ]"; then
  echo "✗ failed to attach two clients"
  exit 1
fi

tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full
tty_a="$(tmx list-clients -F "#{session_name}|#{client_tty}" | awk -F'|' -v s="$SESSION_A" '$1==s{print $2; exit}')"
tty_b="$(tmx list-clients -F "#{session_name}|#{client_tty}" | awk -F'|' -v s="$SESSION_B" '$1==s{print $2; exit}')"
if [ -z "$tty_a" ] || [ -z "$tty_b" ]; then
  echo "✗ missing client tty capture"
  exit 1
fi

TARGET_SESSION=""
TARGET_TTY=""
CONTROL_TTY=""

if session_has_sidebar "$SESSION_A"; then
  TARGET_SESSION="$SESSION_A"
  TARGET_TTY="$tty_a"
  CONTROL_TTY="$tty_b"
elif session_has_sidebar "$SESSION_B"; then
  TARGET_SESSION="$SESSION_B"
  TARGET_TTY="$tty_b"
  CONTROL_TTY="$tty_a"
elif enable_sidebar_for_session "$SESSION_A"; then
  TARGET_SESSION="$SESSION_A"
  TARGET_TTY="$tty_a"
  CONTROL_TTY="$tty_b"
elif enable_sidebar_for_session "$SESSION_B"; then
  TARGET_SESSION="$SESSION_B"
  TARGET_TTY="$tty_b"
  CONTROL_TTY="$tty_a"
else
  echo "✗ failed to enable sidebar for either client-targeted session"
  exit 1
fi

before_target="$(window_for_client_tty "$TARGET_TTY")"
before_control="$(window_for_client_tty "$CONTROL_TTY")"
before_count="$(tmx list-windows -t "$TARGET_SESSION" | wc -l | tr -d ' ')"

"$PROJECT_ROOT/bin/new-window" -session "$TARGET_SESSION" -client-tty "$TARGET_TTY" >/dev/null 2>&1 || {
  echo "✗ new-window binary failed for client A"
  exit 1
}

after_count="$(tmx list-windows -t "$TARGET_SESSION" | wc -l | tr -d ' ')"
if [ "$after_count" -ne $((before_count + 1)) ]; then
  echo "✗ window count did not increase after client-targeted new-window"
  exit 1
fi

after_target="$(window_for_client_tty "$TARGET_TTY")"
after_control="$(window_for_client_tty "$CONTROL_TTY")"
if [ "$after_target" = "$before_target" ]; then
  echo "✗ client A did not switch to the new window"
  echo "target_session=$TARGET_SESSION target_tty=$TARGET_TTY before=$before_target after=$after_target"
  exit 1
fi
if [ "$after_control" != "$before_control" ]; then
  echo "✗ client B unexpectedly switched windows"
  echo "target_session=$TARGET_SESSION target_tty=$TARGET_TTY control_tty=$CONTROL_TTY before_target=$before_target after_target=$after_target before_control=$before_control after_control=$after_control"
  tmx list-clients -F "#{session_name}|#{client_tty}|#{window_id}|#{window_name}|#{pane_id}" || true
  tmx list-windows -a -F "#{session_name}|#{window_id}|#{window_name}|#{window_active}" || true
  exit 1
fi

if ! wait_for 40 window_has_sidebar "$after_target"; then
  echo "✗ new window is missing sidebar renderer"
  tmx list-panes -t "$after_target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
  exit 1
fi

dup_renderers="$(tmx list-windows -a -F "#{window_id}" | while read -r wid; do
  [ -z "$wid" ] && continue
  count="$(tmx list-panes -t "$wid" -F "#{pane_current_command}|#{pane_start_command}" | awk -F'|' '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ {c++} END {print c+0}')"
  if [ "$count" -gt 1 ]; then
    echo "$wid"
  fi
done | wc -l | tr -d ' ')"
if [ "$dup_renderers" -ne 0 ]; then
  echo "✗ found windows with duplicate sidebar renderers"
  exit 1
fi

echo "=== Live multi-client routing test passed ==="
