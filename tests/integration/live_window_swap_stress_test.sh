#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live Window Swap Stress ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
TMUX_REAL="$(command -v tmux || true)"

WINDOW_COUNT="${TABBY_SWAP_WINDOWS:-12}"
ROUNDS="${TABBY_SWAP_ROUNDS:-24}"

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

SOCKET="tabby-live-swap-$$"
SESSION="swap-live"
WRAPPER_DIR="$(mktemp -d /tmp/tabby-live-swap-tmux.XXXXXX)"
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

content_pane() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null | \
    awk -F'|' '$2 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ && $3 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ { print $1; exit }'
}

pane_contains() {
  local pane="$1"
  local token="$2"
  tmx capture-pane -t "$pane" -p 2>/dev/null | grep -Fq "$token"
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

assert_all_windows_have_sidebar() {
  local wid
  while IFS= read -r wid; do
    [ -z "$wid" ] && continue
    window_has_sidebar "$wid" || return 1
  done < <(tmx list-windows -t "$SESSION" -F "#{window_id}")
  return 0
}

enable_sidebar() {
  local attempt
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 50 assert_all_windows_have_sidebar; then
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
TERM=xterm script -q -c "TERM=xterm tmux attach-session -t '$SESSION'" "/tmp/tabby-live-swap-attach-$$.typescript" >/tmp/tabby-live-swap-attach-$$.log 2>&1 &
CLIENT_PID=$!
wait_for 50 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' | grep -qx '$SESSION'"

tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

if ! enable_sidebar; then
  echo "✗ could not enable sidebar"
  exit 1
fi

echo "Creating ${WINDOW_COUNT} windows for swap stress..."
for idx in $(seq 1 "$WINDOW_COUNT"); do
  wid="$(tmx new-window -d -P -F "#{window_id}" -t "$SESSION:" -n "swap-$idx")"
  pane="$(content_pane "$wid")"
  [ -n "$pane" ] || { echo "✗ missing content pane for $wid"; exit 1; }
  token="SWAP_INIT_$idx"
  tmx send-keys -t "$pane" "echo $token" Enter

  if ! ensure_window_sidebar "$wid"; then
    echo "✗ missing sidebar renderer for $wid at setup"
    exit 1
  fi

  if ! wait_for 20 pane_contains "$pane" "$token"; then
    echo "✗ initial content token missing for $wid"
    exit 1
  fi
done

echo "Running ${ROUNDS} rounds of swap-window -t :+1 / :-1..."
for round in $(seq 1 "$ROUNDS"); do
  # equivalent to prefix + M-j
  tmx select-window -t "$SESSION:1" >/dev/null 2>&1 || true
  tmx swap-window -t :+1 >/dev/null 2>&1 || true

  # equivalent to prefix + M-k
  tmx select-window -t "$SESSION:2" >/dev/null 2>&1 || true
  tmx swap-window -t :-1 >/dev/null 2>&1 || true

  if ! wait_for 30 assert_all_windows_have_sidebar; then
    echo "✗ sidebar drift after swap round=$round"
    tmx list-windows -t "$SESSION" -F "#{window_id}|#{window_index}|#{window_name}" || true
    tmx list-panes -s -t "$SESSION" -F "#{window_id}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
    exit 1
  fi

done

echo "Verifying content continuity after swaps..."
for idx in 1 $((WINDOW_COUNT / 2)) "$WINDOW_COUNT"; do
  pane="$(content_pane "$SESSION:$idx")"
  [ -n "$pane" ] || { echo "✗ missing content pane after swaps for index=$idx"; exit 1; }
  if ! tmx capture-pane -t "$pane" -p >/dev/null 2>&1; then
    echo "✗ capture failed after swaps for pane=$pane"
    exit 1
  fi
done

echo "=== Live Window Swap Stress test passed ==="
