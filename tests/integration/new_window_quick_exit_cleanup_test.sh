#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: New window quick-exit cleanup ==="

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

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ] || [ ! -x "$PROJECT_ROOT/bin/new-window" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-new-window-quick-exit-$$"
SESSION="tabby-new-window-quick-exit"
CLIENT_PIDS=""
SESSION_ID=""
WRAPPER_DIR="$(mktemp -d /tmp/tabby-new-window-quick-exit-tmux.XXXXXX)"

cat > "$WRAPPER_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_REAL" -L "$SOCKET" -f /dev/null "\$@"
EOF
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

tmx() {
  "$TMUX_REAL" -L "$SOCKET" -f /dev/null "$@"
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

seed_tabby_tmux_env() {
  local socket_path
  socket_path="$(tmx display-message -p '#{socket_path}')"
  tmx set-environment -g TABBY_TMUX_SOCKET "$socket_path"
  tmx set-environment -g TABBY_TMUX_REAL "$TMUX_REAL"
}

cleanup() {
  local pid_file watchdog_file pid
  for pid in $CLIENT_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  if [ -n "$SESSION_ID" ]; then
    pid_file="/tmp/tabby-daemon-${SESSION_ID}.pid"
    watchdog_file="/tmp/tabby-daemon-${SESSION_ID}.watchdog.pid"
    if [ -f "$pid_file" ]; then
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    fi
    if [ -f "$watchdog_file" ]; then
      pid="$(cat "$watchdog_file" 2>/dev/null || true)"
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "/tmp/tabby-daemon-${SESSION_ID}.pid" \
      "/tmp/tabby-daemon-${SESSION_ID}.sock" \
      "/tmp/tabby-daemon-${SESSION_ID}-events.log" \
      "/tmp/tabby-daemon-${SESSION_ID}.input.log" \
      "/tmp/tabby-daemon-${SESSION_ID}.clean-stop" \
      "/tmp/tabby-daemon-${SESSION_ID}.watchdog.pid"
  fi
  tmx kill-server >/dev/null 2>&1 || true
  rm -rf "$WRAPPER_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_attached_client() {
  local typescript="/tmp/tabby-new-window-quick-exit-$$.typescript"
  local log_file="/tmp/tabby-new-window-quick-exit-$$.log"
  TERM=xterm script -q -c "TERM=xterm $TMUX_REAL -L $SOCKET -f /dev/null attach-session -t $SESSION" "$typescript" >"$log_file" 2>&1 &
  local pid=$!
  CLIENT_PIDS="$CLIENT_PIDS $pid"
  if ! wait_for 30 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"; then
    echo "✗ failed to attach client for $SESSION"
    [ -f "$log_file" ] && sed -n '1,80p' "$log_file" || true
    exit 1
  fi
}

session_has_sidebar() {
  tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
    | grep -Eq "(sidebar-renderer|sidebar)"
}

content_pane() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}|#{pane_dead}" 2>/dev/null \
    | awk -F'|' '$4 != "1" && $2 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ && $3 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ { print $1; exit }'
}

window_has_only_system_panes() {
  local target="$1"
  local summary
  summary="$(tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}|#{pane_dead}" 2>/dev/null | awk -F'|' '
    $3 != "1" {
      if ($1 ~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ || $2 ~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/) {
        system_count++
      } else {
        main_count++
      }
    }
    END { printf "%d %d\n", system_count+0, main_count+0 }'
  )"
  [ -n "$summary" ] || return 1
  local system_count main_count
  system_count="$(printf '%s' "$summary" | awk '{print $1}')"
  main_count="$(printf '%s' "$summary" | awk '{print $2}')"
  [ "${system_count:-0}" -gt 0 ] && [ "${main_count:-0}" -eq 0 ]
}

no_orphan_windows() {
  local wid
  while IFS= read -r wid; do
    [ -z "$wid" ] && continue
    if window_has_only_system_panes "$wid"; then
      return 1
    fi
  done < <(tmx list-windows -t "$SESSION" -F "#{window_id}" 2>/dev/null || true)
  return 0
}

window_count_is() {
  local expected="$1"
  local count
  count="$(tmx list-windows -t "$SESSION" -F "#{window_id}" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" = "$expected" ]
}

client_window_id() {
  tmx list-clients -F "#{session_name}|#{window_id}" 2>/dev/null | awk -F'|' -v s="$SESSION" '$1 == s { print $2; exit }'
}

client_window_is() {
  local expected="$1"
  [ "$(client_window_id)" = "$expected" ]
}

client_window_is_one_of() {
  local first="$1"
  local second="$2"
  local current
  current="$(client_window_id)"
  [ "$current" = "$first" ] || [ "$current" = "$second" ]
}

client_window_is_not() {
  local unexpected="$1"
  local current
  current="$(client_window_id)"
  [ -n "$current" ] && [ "$current" != "$unexpected" ]
}

return_client_to_base_window() {
  local target="$1"
  local tty="$2"
  tmx switch-client -c "$tty" -t "$target" >/dev/null 2>&1 || true
  client_window_is "$base_window_id"
}

client_tty() {
  tmx list-clients -F "#{session_name}|#{client_tty}" 2>/dev/null | awk -F'|' -v s="$SESSION" '$1 == s { print $2; exit }'
}

dump_state() {
  echo "--- clients ---"
  tmx list-clients -F "#{session_name}|#{client_tty}|#{window_id}|#{window_name}" 2>/dev/null || true
  echo "--- windows ---"
  tmx list-windows -t "$SESSION" -F "#{window_id}|#{window_index}|#{window_name}|#{window_active}|#{window_layout}" 2>/dev/null || true
  echo "--- panes ---"
  tmx list-panes -s -t "$SESSION" -F "#{window_id}|#{window_name}|#{pane_id}|#{pane_current_command}|#{pane_start_command}|#{pane_active}|#{pane_dead}" 2>/dev/null || true
}

enable_sidebar() {
  local attempt
  tmx set-option -g @tabby_sidebar_position left
  tmx set-option -g @tabby_sidebar_mode full
  tmx set-option -g @tabby_pane_headers off
  SESSION_ID="$(tmx display-message -p -t "$SESSION:" '#{session_id}' 2>/dev/null || true)"
  if [ -n "$SESSION_ID" ]; then
    rm -f "/tmp/tabby-daemon-${SESSION_ID}.pid" \
      "/tmp/tabby-daemon-${SESSION_ID}.sock" \
      "/tmp/tabby-daemon-${SESSION_ID}-events.log" \
      "/tmp/tabby-daemon-${SESSION_ID}.input.log" \
      "/tmp/tabby-daemon-${SESSION_ID}.clean-stop" \
      "/tmp/tabby-daemon-${SESSION_ID}.watchdog.pid"
  fi
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 50 session_has_sidebar; then
      return 0
    fi
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.4
  done
  echo "✗ sidebar failed to start"
  dump_state
  exit 1
}

tmx new-session -d -s "$SESSION" -n "one"
tmx new-window -t "$SESSION:" -n "two"
seed_tabby_tmux_env
tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
start_attached_client
enable_sidebar

base_window_id="$(tmx display-message -p -t "$SESSION:0" "#{window_id}" 2>/dev/null || true)"
fallback_window_id="$(tmx display-message -p -t "$SESSION:1" "#{window_id}" 2>/dev/null || true)"
client_tty_value="$(client_tty)"
if [ -z "$base_window_id" ] || [ -z "$fallback_window_id" ] || [ -z "$client_tty_value" ]; then
  echo "✗ failed to capture initial client state"
  dump_state
  exit 1
fi

for attempt in $(seq 1 10); do
  if ! wait_for 50 return_client_to_base_window "$SESSION:0" "$client_tty_value"; then
    echo "✗ failed to return client to base window on attempt $attempt"
    dump_state
    exit 1
  fi

  before_count="$(tmx list-windows -t "$SESSION" -F "#{window_id}" | wc -l | tr -d ' ')"
  "$PROJECT_ROOT/bin/new-window" -session "$SESSION" -client-tty "$client_tty_value" >/dev/null 2>&1 || {
    echo "✗ new-window binary failed on attempt $attempt"
    exit 1
  }

  if ! wait_for 20 window_count_is $((before_count + 1)); then
    echo "✗ new-window did not create a third window on attempt $attempt"
    dump_state
    exit 1
  fi

  if ! wait_for 20 client_window_is_not "$base_window_id"; then
    echo "✗ client did not land in the newly created window on attempt $attempt"
    dump_state
    exit 1
  fi

  quick_window_id="$(client_window_id)"
  if [ -z "$quick_window_id" ] || [ "$quick_window_id" = "$base_window_id" ]; then
    echo "✗ client did not land in the newly created window on attempt $attempt"
    dump_state
    exit 1
  fi

  quick_pane="$(content_pane "$quick_window_id")"
  if [ -z "$quick_pane" ]; then
    echo "✗ no content pane found in quick-exit window on attempt $attempt"
    dump_state
    exit 1
  fi

  tmx send-keys -t "$quick_pane" exit C-m

  if ! wait_for 30 window_count_is "$before_count"; then
    echo "✗ quick new-window exit left an extra window behind on attempt $attempt"
    dump_state
    exit 1
  fi
  if ! wait_for 30 no_orphan_windows; then
    echo "✗ quick new-window exit left a renderer-only orphan on attempt $attempt"
    dump_state
    exit 1
  fi
  if ! wait_for 30 client_window_is_one_of "$base_window_id" "$fallback_window_id"; then
    echo "✗ quick new-window exit did not return focus to a surviving content window on attempt $attempt"
    dump_state
    exit 1
  fi
done

echo "✓ quickly exiting newly created windows does not leave fullscreen renderer orphans"
echo "=== New window quick-exit cleanup test passed ==="
