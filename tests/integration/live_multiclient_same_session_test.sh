#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live multi-client same-session routing ==="

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
SESSION="multi-client"
WRAPPER_DIR="$(mktemp -d /tmp/tabby-live-multiclient-tmux.XXXXXX)"
CLIENT_PIDS=""

cat > "$WRAPPER_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_REAL" -L "$SOCKET" -f /dev/null "\$@"
EOF
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

tmx() { command tmux "$@"; }

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
  tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

window_has_sidebar() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

enable_sidebar_for_session() {
  local attempt
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 40 session_has_sidebar; then
      return 0
    fi
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.4
  done
  return 1
}

start_client() {
  local label="$1"
  local typescript="/tmp/tabby-live-multiclient-${label}-$$.typescript"
  local log_file="/tmp/tabby-live-multiclient-${label}-$$.log"
  TERM=xterm script -q -c "TERM=xterm tmux attach-session -t '$SESSION'" "$typescript" >"$log_file" 2>&1 &
  CLIENT_PIDS="$CLIENT_PIDS $!"
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "main"
tmx new-window -t "$SESSION:" -n "other"
start_client "a"
start_client "b"

if ! wait_for 40 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -t '$SESSION' | wc -l | tr -d ' ' | grep -qx '2'"; then
  echo "✗ failed to attach two clients"
  exit 1
fi

tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full
if ! enable_sidebar_for_session; then
  echo "✗ failed to enable sidebar in same-session multi-client test"
  exit 1
fi

tty_a="$(tmx list-clients -t "$SESSION" -F "#{client_tty}" | sed -n '1p')"
tty_b="$(tmx list-clients -t "$SESSION" -F "#{client_tty}" | sed -n '2p')"
if [ -z "$tty_a" ] || [ -z "$tty_b" ]; then
  echo "✗ missing client tty capture"
  exit 1
fi

tmx switch-client -c "$tty_a" -t "$SESSION:0"
tmx switch-client -c "$tty_b" -t "$SESSION:1"

if ! wait_for 20 bash -lc "[ \"\$(tmux -L '$SOCKET' -f /dev/null display-message -p -c '$tty_a' '#{window_id}')\" != \"\$(tmux -L '$SOCKET' -f /dev/null display-message -p -c '$tty_b' '#{window_id}')\" ]"; then
  echo "✗ setup failed: clients did not diverge to different windows"
  exit 1
fi

before_a="$(tmx display-message -p -c "$tty_a" "#{window_id}")"
before_b="$(tmx display-message -p -c "$tty_b" "#{window_id}")"
before_count="$(tmx list-windows -t "$SESSION" | wc -l | tr -d ' ')"

if [ "$before_a" = "$before_b" ]; then
  echo "✗ setup failed: both clients on same window before new-window test"
  exit 1
fi

"$PROJECT_ROOT/bin/new-window" -client-tty "$tty_a" >/dev/null 2>&1 || {
  echo "✗ new-window binary failed for client A"
  exit 1
}

after_count="$(tmx list-windows -t "$SESSION" | wc -l | tr -d ' ')"
if [ "$after_count" -ne $((before_count + 1)) ]; then
  echo "✗ window count did not increase after client-targeted new-window"
  exit 1
fi

after_a="$(tmx display-message -p -c "$tty_a" "#{window_id}")"
after_b="$(tmx display-message -p -c "$tty_b" "#{window_id}")"
if [ "$after_a" = "$before_a" ]; then
  echo "✗ client A did not switch to the new window"
  exit 1
fi
if [ "$after_b" != "$before_b" ]; then
  echo "✗ client B unexpectedly switched windows"
  exit 1
fi

if ! wait_for 40 window_has_sidebar "$after_a"; then
  echo "✗ new window is missing sidebar renderer"
  tmx list-panes -t "$after_a" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
  exit 1
fi

dup_renderers="$(tmx list-windows -t "$SESSION" -F "#{window_id}" | while read -r wid; do
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

echo "=== Live multi-client same-session routing test passed ==="
