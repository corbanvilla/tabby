#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live Toggle Concurrency ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required for this test" >&2
  exit 1
fi

if ! command -v script >/dev/null 2>&1; then
  echo "script(1) is required for this test" >&2
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
  echo "Building binaries..."
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

TABBY_TEST_SOCKET="tabby-live-toggle-$$"
WRAPPER_DIR="$(mktemp -d /tmp/tabby-live-toggle-tmux.XXXXXX)"
ATTACH_TS="/tmp/tabby-live-toggle-attach-$$.typescript"
ATTACH_LOG="/tmp/tabby-live-toggle-attach-$$.log"
TOGGLE_LOG="/tmp/tabby-live-toggle-toggle-$$.log"
MUTATE_LOG="/tmp/tabby-live-toggle-mutate-$$.log"
SESSION_NAME="tabby-live-toggle-test"
CLIENT_PID=""
TOGGLE_PID=""
MUTATE_PID=""

cat > "$WRAPPER_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$(command -v tmux)" -L "$TABBY_TEST_SOCKET" -f /dev/null "\$@"
EOF
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

tmux_session_id=""

cleanup() {
  local exit_code=$?
  [ -n "${MUTATE_PID:-}" ] && kill "$MUTATE_PID" >/dev/null 2>&1 || true
  [ -n "${TOGGLE_PID:-}" ] && kill "$TOGGLE_PID" >/dev/null 2>&1 || true
  [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" >/dev/null 2>&1 || true
  tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$WRAPPER_DIR" >/dev/null 2>&1 || true
  rm -f "$ATTACH_TS" "$ATTACH_LOG" "$TOGGLE_LOG" "$MUTATE_LOG" >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap cleanup EXIT

die() {
  echo "✗ $*" >&2
  echo "--- tmux windows ---" >&2
  tmux list-windows -t "$SESSION_NAME" -F '#{window_id}|#{window_index}|#{window_name}' 2>/dev/null || true
  echo "--- tmux panes ---" >&2
  tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}|#{window_id}|#{window_name}|#{pane_id}|#{pane_current_command}|#{pane_start_command}' 2>/dev/null || true
  echo "--- mode ---" >&2
  read_mode 2>/dev/null | sed 's/^/mode: /' >&2 || true
  echo "--- attach log ---" >&2
  tail -n 40 "$ATTACH_LOG" 2>/dev/null || true
  echo "--- toggle log ---" >&2
  tail -n 40 "$TOGGLE_LOG" 2>/dev/null || true
  echo "--- mutate log ---" >&2
  tail -n 40 "$MUTATE_LOG" 2>/dev/null || true
  exit 1
}

wait_for() {
  local tries="$1"
  shift
  local stable=0
  local i
  for i in $(seq 1 "$tries"); do
    if "$@"; then
      stable=$((stable + 1))
      if [ "$stable" -ge 2 ]; then
        return 0
      fi
    else
      stable=0
    fi
    sleep 0.1
  done
  return 1
}

read_mode() {
  local mode=""
  mode="$(tmux show-options -t "$SESSION_NAME" -qv @tabby_sidebar 2>/dev/null || true)"
  if [ -z "$mode" ]; then
    mode="$(tmux show-option -gqv @tabby_sidebar 2>/dev/null || true)"
  fi
  printf '%s' "$mode"
}

live_window_ids() {
  tmux list-windows -t "$SESSION_NAME" -F '#{window_id}' 2>/dev/null || true
}

count_live_windows() {
  live_window_ids | sed '/^$/d' | wc -l | tr -d ' '
}

count_renderers_total() {
  tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_current_command}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ { c++ } END { print c+0 }'
}

count_daemon_panes() {
  tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_current_command}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '$1 ~ /tabby-daemon/ || $2 ~ /tabby-daemon/ { c++ } END { print c+0 }'
}

count_disabled_system_panes() {
  tmux list-panes -s -t "$SESSION_NAME" -F '#{pane_current_command}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '
        $1 ~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ ||
        $2 ~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ { c++ }
        END { print c+0 }
      '
}

window_renderer_count() {
  local window_id="$1"
  tmux list-panes -t "$window_id" -F '#{pane_current_command}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ { c++ } END { print c+0 }'
}

window_exists() {
  local window_id="$1"
  live_window_ids | grep -qx "$window_id"
}

content_pane_id() {
  local window_id="$1"
  tmux list-panes -t "$window_id" -F '#{pane_id}|#{pane_current_command}|#{pane_start_command}' 2>/dev/null \
    | awk -F'|' '
        $2 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ &&
        $3 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ { print $1; exit }
      '
}

assert_enabled_consistency() {
  local live_windows renderer_total daemon_total window_id renderer_count
  live_windows="$(count_live_windows)"
  renderer_total="$(count_renderers_total)"
  daemon_total="$(count_daemon_panes)"

  if [ "$daemon_total" -ne 0 ]; then
    return 1
  fi

  if [ "$renderer_total" -ne "$live_windows" ]; then
    return 1
  fi

  while IFS= read -r window_id; do
    [ -z "$window_id" ] && continue
    renderer_count="$(window_renderer_count "$window_id")"
    if [ "$renderer_count" -ne 1 ]; then
      return 1
    fi
  done < <(live_window_ids)

  return 0
}

assert_disabled_consistency() {
  local system_total
  system_total="$(count_disabled_system_panes)"
  [ "$system_total" -eq 0 ]
}

wait_for_consistency() {
  local mode="$1"
  if [ "$mode" = "enabled" ]; then
    wait_for 80 assert_enabled_consistency
    return $?
  fi
  if [ "$mode" = "disabled" ]; then
    wait_for 80 assert_disabled_consistency
    return $?
  fi
  return 1
}

current_consistency() {
  local mode
  mode="$(read_mode)"
  case "$mode" in
    enabled) assert_enabled_consistency ;;
    disabled) assert_disabled_consistency ;;
    *) return 1 ;;
  esac
}

wait_for_current_consistency() {
  wait_for 80 current_consistency
}

wait_for_window_gone() {
  local window_id="$1"
  wait_for 60 window_missing "$window_id"
}

window_missing() {
  local window_id="$1"
  ! window_exists "$window_id"
}

set_mode() {
  local desired="$1"
  local current
  local attempt

  for attempt in 1 2 3; do
    current="$(read_mode)"
    if [ "$current" != "$desired" ]; then
      tmux run-shell -b -t "$SESSION_NAME:" "bash '$PROJECT_ROOT/scripts/toggle_sidebar.sh'" >/dev/null 2>&1 || true
    fi
    if wait_for_consistency "$desired"; then
      return 0
    fi
    sleep 0.1
  done

  return 1
}

ensure_window_sidebar() {
  local window_id="$1"
  tmux run-shell -b -t "$SESSION_NAME:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh \"$tmux_session_id\" \"$window_id\"" >/dev/null 2>&1 || true
  sleep 0.1
}

cleanup_orphan_window() {
  local window_id="$1"
  tmux run-shell -b -t "$SESSION_NAME:" "$PROJECT_ROOT/scripts/cleanup_orphan_sidebar.sh \"$tmux_session_id\" \"$window_id\"" >/dev/null 2>&1 || true
  sleep 0.1
}

attach_client() {
  TERM=xterm script -q -c "TERM=xterm tmux attach-session -t '$SESSION_NAME'" "$ATTACH_TS" >"$ATTACH_LOG" 2>&1 &
  CLIENT_PID=$!
  if ! wait_for 50 bash -lc "tmux list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION_NAME'"; then
    die "failed to attach a real tmux client"
  fi
}

make_window() {
  local short_name="$1"
  local renamed="$2"
  local window_id

  window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION_NAME:" -n "$short_name" 'sleep 600')"
  tmux rename-window -t "$window_id" "$renamed"
  tmux select-window -t "$window_id"
  ensure_window_sidebar "$window_id"
  wait_for_current_consistency
  printf '%s' "$window_id"
}

kill_orphan_content_window() {
  local window_id="$1"
  local pane_id

  pane_id=""
  local retry
  for retry in 1 2 3 4 5; do
    pane_id="$(content_pane_id "$window_id")"
    [ -n "$pane_id" ] && break
    sleep 0.05
  done
  [ -n "$pane_id" ] || return 1

  tmux kill-pane -t "$pane_id" >/dev/null 2>&1 || true
  cleanup_orphan_window "$window_id"
  if ! wait_for_window_gone "$window_id"; then
    return 1
  fi
  wait_for_current_consistency
}

kill_window() {
  local window_id="$1"
  tmux kill-window -t "$window_id" >/dev/null 2>&1 || true
  if ! wait_for_window_gone "$window_id"; then
    return 1
  fi
  wait_for_current_consistency
}

run_toggler() {
  local target
  for target in disabled enabled disabled enabled; do
    echo "toggle -> $target"
    if ! set_mode "$target"; then
      return 1
    fi
    echo "state settled at $target"
  done
}

run_mutator() {
  local alpha beta gamma delta

  echo "creating alpha"
  alpha="$(make_window alpha alpha-renamed)"
  echo "alpha id: $alpha"

  echo "orphaning alpha"
  if ! kill_orphan_content_window "$alpha"; then
    return 1
  fi

  echo "creating beta"
  beta="$(make_window beta beta-renamed)"
  echo "beta id: $beta"

  echo "closing beta"
  if ! kill_window "$beta"; then
    return 1
  fi

  echo "creating gamma"
  gamma="$(make_window gamma gamma-renamed)"
  echo "gamma id: $gamma"

  echo "creating delta"
  delta="$(make_window delta delta-renamed)"
  echo "delta id: $delta"

  echo "retouching gamma and delta"
  tmux rename-window -t "$gamma" "gamma-final" >/dev/null 2>&1 || true
  tmux rename-window -t "$delta" "delta-final" >/dev/null 2>&1 || true
  tmux select-window -t "$gamma" >/dev/null 2>&1 || true
  ensure_window_sidebar "$gamma"
  ensure_window_sidebar "$delta"
  wait_for_current_consistency

  echo "done"
}

tmux start-server
tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
tmux new-session -d -s "$SESSION_NAME" -n main -c "$PROJECT_ROOT"
tmux set-option -g @tabby_sidebar_position left
tmux set-option -g @tabby_sidebar_mode full

tmux_session_id="$(tmux display-message -p -t "$SESSION_NAME" '#{session_id}')"
DAEMON_PID_FILE="/tmp/tabby-daemon-${tmux_session_id}.pid"

attach_client

if ! set_mode enabled; then
  die "failed to reach enabled sidebar mode"
fi

run_toggler >"$TOGGLE_LOG" 2>&1 &
TOGGLE_PID=$!
run_mutator >"$MUTATE_LOG" 2>&1 &
MUTATE_PID=$!

if ! wait "$TOGGLE_PID"; then
  echo "--- toggle log ---" >&2
  cat "$TOGGLE_LOG" >&2 || true
  die "toggle worker failed"
fi

if ! wait "$MUTATE_PID"; then
  echo "--- mutate log ---" >&2
  cat "$MUTATE_LOG" >&2 || true
  die "mutation worker failed"
fi

if ! set_mode enabled; then
  die "failed to re-stabilize in enabled mode"
fi

if ! wait_for_consistency enabled; then
  die "enabled consistency check failed after concurrent churn"
fi

if ! set_mode disabled; then
  die "failed to settle in disabled mode"
fi

if ! wait_for_consistency disabled; then
  die "disabled consistency check failed after teardown"
fi

echo "=== Live toggle concurrency test passed ==="
