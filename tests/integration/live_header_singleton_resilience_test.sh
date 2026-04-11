#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live header singleton resilience ==="

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

if [ ! -x "$PROJECT_ROOT/bin/pane-header" ] || [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-header-$$"
SESSION="hdr-live"
WRAPPER_DIR="$(mktemp -d /tmp/tabby-live-header-tmux.XXXXXX)"
CLIENT_PID=""

cat > "$WRAPPER_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_REAL" -L "$SOCKET" -f /dev/null "\$@"
EOF
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

tmx() { command tmux "$@"; }

seed_tabby_tmux_env() {
  local socket_path
  socket_path="$(tmx display-message -p '#{socket_path}')"
  tmx set-environment -g TABBY_TMUX_SOCKET "$socket_path"
  tmx set-environment -g TABBY_TMUX_REAL "$TMUX_REAL"
}

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
    sleep 0.2
  done
  return 1
}

header_like_count() {
  tmx list-panes -a -F "#{?@tabby_role,#{@tabby_role},}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
    | awk -F'|' '$1=="pane-header" || $2 ~ /pane-header/ || $3 ~ /pane-header/ {c++} END {print c+0}'
}

window_count() {
  tmx list-windows -t "$SESSION" 2>/dev/null | wc -l | tr -d ' '
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "main"
seed_tabby_tmux_env
wait_for 30 tmx has-session -t "$SESSION" >/dev/null 2>&1 || true
TERM=xterm script -q -c "TERM=xterm $TMUX_REAL -L $SOCKET -f /dev/null attach-session -t '$SESSION'" "/tmp/tabby-live-header-attach-$$.typescript" >/tmp/tabby-live-header-attach-$$.log 2>&1 &
CLIENT_PID=$!

if ! wait_for 40 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' | grep -qx '$SESSION'"; then
  echo "✗ failed to attach client"
  exit 1
fi

tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx set-option -g @tabby_pane_headers on

if ! wait_for 50 bash -lc "[ \"\$(tmux -L '$SOCKET' -f /dev/null list-panes -a -F '#{?@tabby_role,#{@tabby_role},}|#{pane_current_command}|#{pane_start_command}' 2>/dev/null | awk -F'|' '\$1==\"pane-header\" || \$2 ~ /pane-header/ || \$3 ~ /pane-header/ {c++} END {print c+0}')\" -le \"\$((\$(tmux -L '$SOCKET' -f /dev/null list-windows -t '$SESSION' 2>/dev/null | wc -l | tr -d ' ') + 1))\" ]"; then
  echo "✗ initial header state invalid"
  exit 1
fi

# Crash current pane-header process(es) to simulate the user-reported loop trigger.
for pid in $(tmx list-panes -a -F "#{pane_pid} #{pane_current_command}" | awk '$2=="pane-header"{print $1}'); do
  kill -9 "$pid" >/dev/null 2>&1 || true
done

# Observe for ~12 seconds. We allow brief overlap right after a crash, but fail on
# sustained growth beyond window_count+1 (the runaway stacking pattern).
wc="$(window_count)"
limit=$((wc + 1))
over_limit_streak=0
max_seen=0
for _ in $(seq 1 12); do
  hc="$(header_like_count)"
  if [ "$hc" -gt "$max_seen" ]; then
    max_seen="$hc"
  fi
  if [ "$hc" -gt "$limit" ]; then
    over_limit_streak=$((over_limit_streak + 1))
  else
    over_limit_streak=0
  fi
  if [ "$over_limit_streak" -ge 2 ]; then
    echo "✗ header count is growing beyond safe bound (runaway topbar spawn)"
    tmx list-panes -a -F "#{window_id}|#{pane_id}|#{?@tabby_role,#{@tabby_role},}|#{?@tabby_target_pane,#{@tabby_target_pane},}|#{pane_current_command}|#{pane_start_command}" || true
    exit 1
  fi
  sleep 1
done

echo "observed max header-like count: $max_seen (window_count=$wc)"

echo "=== Live header singleton resilience test passed ==="
