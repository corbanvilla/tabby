#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live Window Burst Recovery ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
TMUX_REAL="$(command -v tmux || true)"

BURSTS="${TABBY_BURST_COUNT:-5}"
WINDOWS_PER_BURST="${TABBY_BURST_WINDOWS:-4}"

if [ -z "$TMUX_REAL" ]; then
  echo "tmux is required"
  exit 1
fi

if ! command -v script >/dev/null 2>&1; then
  echo "script(1) is required"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ] || [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ]; then
  echo "Building tabby binaries..."
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-burst-$$"
SESSION="burst-live"
WRAPPER_DIR="$(mktemp -d /tmp/tabby-live-burst-tmux.XXXXXX)"
CLIENT_PID=""

cat > "$WRAPPER_DIR/tmux" <<WRAP
#!/usr/bin/env bash
exec "$TMUX_REAL" -L "$SOCKET" -f /dev/null "\$@"
WRAP
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

tmx() { command tmux "$@"; }

cleanup() {
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" >/dev/null 2>&1 || true
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
    sleep 0.15
  done
  return 1
}

window_has_sidebar() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

session_renderer_count() {
  tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | \
    awk -F'|' '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ { c++ } END { print c+0 }'
}

session_window_count() {
  tmx list-windows -t "$SESSION" 2>/dev/null | wc -l | tr -d ' '
}

ensure_window_sidebar() {
  local target="$1"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if wait_for 30 window_has_sidebar "$target"; then
      return 0
    fi
    TABBY_TMUX_SOCKET="$TABBY_TMUX_SOCKET" "$PROJECT_ROOT/scripts/signal_sidebar.sh" >/dev/null 2>&1 || true
    TABBY_TMUX_SOCKET="$TABBY_TMUX_SOCKET" "$PROJECT_ROOT/scripts/ensure_sidebar.sh" _ "$target" >/dev/null 2>&1 || true
    sleep 0.2
  done
  return 1
}

enable_sidebar() {
  local attempt
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 40 bash -lc "tmux -L '$SOCKET' -f /dev/null show-options -gqv @tabby_sidebar | grep -qx enabled"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "main"
export TABBY_TMUX_SOCKET
TABBY_TMUX_SOCKET="$(tmx display-message -p '#{socket_path}')"
TERM=xterm script -q -c "TERM=xterm tmux attach-session -t '$SESSION'" "/tmp/tabby-live-burst-attach-$$.typescript" >/tmp/tabby-live-burst-attach-$$.log 2>&1 &
CLIENT_PID=$!
wait_for 50 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' | grep -qx '$SESSION'"

tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

if ! enable_sidebar; then
  echo "✗ could not enable sidebar"
  exit 1
fi

expected_new=$((BURSTS * WINDOWS_PER_BURST))
created=0
missing=0

for burst in $(seq 1 "$BURSTS"); do
  echo "burst=$burst creating $WINDOWS_PER_BURST windows"

  for n in $(seq 1 "$WINDOWS_PER_BURST"); do
    wid="$(tmx new-window -d -P -F "#{window_id}" -t "$SESSION:" -n "burst-${burst}-${n}")"
    created=$((created + 1))

    if ! ensure_window_sidebar "$wid"; then
      echo "miss: no sidebar renderer for $wid (burst=$burst n=$n)"
      missing=$((missing + 1))
    fi

    tmx send-keys -t "$wid" "echo BURST_${burst}_${n}" Enter >/dev/null 2>&1 || true
  done

  # Churn by renaming + selecting windows.
  tmx list-windows -t "$SESSION" -F "#{window_id}" | while read -r w; do
    [ -z "$w" ] && continue
    tmx rename-window -t "$w" "bw-${burst}-${RANDOM}" >/dev/null 2>&1 || true
    tmx select-window -t "$w" >/dev/null 2>&1 || true
  done

done

windows_total="$(session_window_count)"
renderers_total="$(session_renderer_count)"

echo "created=$created expected_new=$expected_new missing=$missing windows_total=$windows_total renderers_total=$renderers_total"

if [ "$missing" -gt 0 ]; then
  echo "✗ at least one new window never received a sidebar renderer"
  exit 1
fi

if [ "$renderers_total" -lt "$windows_total" ]; then
  echo "✗ renderer deficit after burst churn"
  exit 1
fi

echo "=== Live Window Burst Recovery test passed ==="
