#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live seeded fuzz trajectory ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
TMUX_REAL="$(command -v tmux)"
SEED="${TABBY_FUZZ_SEED:-424242}"
STEPS="${TABBY_FUZZ_STEPS:-80}"

if [ -z "$TMUX_REAL" ]; then
  echo "tmux is required"
  exit 1
fi

if ! command -v script >/dev/null 2>&1; then
  echo "script(1) is required"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ] || [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-live-fuzz-$$"
SESSION="fuzz-live"
WRAPPER_DIR="$(mktemp -d /tmp/tabby-live-fuzz-tmux.XXXXXX)"
CLIENT_PID=""

cat > "$WRAPPER_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$TMUX_REAL" -L "$SOCKET" -f /dev/null "\$@"
EOF
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

mode_value() {
  tmx show-options -gqv @tabby_sidebar 2>/dev/null || true
}

enabled_consistent() {
  local wins renderers daemon_panes wid c
  wins="$(tmx list-windows -t "$SESSION" -F "#{window_id}" | wc -l | tr -d ' ')"
  renderers="$(tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" | awk -F'|' '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ {c++} END {print c+0}')"
  daemon_panes="$(tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" | awk -F'|' '$1 ~ /tabby-daemon/ || $2 ~ /tabby-daemon/ {c++} END {print c+0}')"
  [ "$daemon_panes" -eq 0 ] || return 1
  [ "$renderers" -eq "$wins" ] || return 1
  while IFS= read -r wid; do
    [ -z "$wid" ] && continue
    c="$(tmx list-panes -t "$wid" -F "#{pane_current_command}|#{pane_start_command}" | awk -F'|' '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ {c++} END {print c+0}')"
    [ "$c" -eq 1 ] || return 1
  done < <(tmx list-windows -t "$SESSION" -F "#{window_id}")
  return 0
}

disabled_consistent() {
  local system_panes
  system_panes="$(tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" | awk -F'|' '$1 ~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ || $2 ~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ {c++} END {print c+0}')"
  [ "$system_panes" -eq 0 ]
}

window_has_sidebar() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

wait_current_consistency() {
  local mode
  mode="$(mode_value)"
  if [ "$mode" = "enabled" ]; then
    wait_for 60 enabled_consistent
    return $?
  fi
  if [ "$mode" = "disabled" ]; then
    wait_for 60 disabled_consistent
    return $?
  fi
  return 1
}

enable_sidebar() {
  local attempt
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 60 enabled_consistent; then
      return 0
    fi
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.3
  done
  return 1
}

set_mode() {
  local desired="$1"
  local cur attempt
  for attempt in 1 2 3; do
    cur="$(mode_value)"
    if [ "$cur" != "$desired" ]; then
      tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh" >/dev/null 2>&1 || true
    fi
    if [ "$desired" = "enabled" ] && wait_for 60 enabled_consistent; then
      return 0
    fi
    if [ "$desired" = "disabled" ] && wait_for 60 disabled_consistent; then
      return 0
    fi
    sleep 0.3
  done
  return 1
}

content_pane() {
  local w="$1"
  tmx list-panes -t "$w" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" | awk -F'|' '$2 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ && $3 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ {print $1; exit}'
}

content_pane_count() {
  tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | \
    awk -F'|' '$1 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ && $2 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ {c++} END {print c+0}'
}

random_window() {
  local count idx
  count="$(tmx list-windows -t "$SESSION" | wc -l | tr -d ' ')"
  if [ "$count" -le 1 ]; then
    echo "$SESSION:0"
    return 0
  fi
  idx=$((RANDOM % count))
  echo "$SESSION:$idx"
}

run_op() {
  local op="$1" target pane new_window_id
  case "$op" in
    0)
      new_window_id="$(tmx new-window -d -P -F "#{window_id}" -t "$SESSION:" -n "fuzz-$RANDOM" 2>/dev/null || true)"
      if [ -n "$new_window_id" ]; then
        TABBY_TMUX_SOCKET="$TABBY_TMUX_SOCKET" "$PROJECT_ROOT/scripts/ensure_sidebar.sh" _ "$new_window_id" >/dev/null 2>&1 || true
        wait_for 20 window_has_sidebar "$new_window_id" >/dev/null 2>&1 || true
      fi
      TABBY_TMUX_SOCKET="$TABBY_TMUX_SOCKET" "$PROJECT_ROOT/scripts/signal_sidebar.sh" >/dev/null 2>&1 || true
      ;;
    1)
      target="$(random_window)"
      tmx rename-window -t "$target" "rn-$RANDOM" >/dev/null 2>&1 || true
      ;;
    2)
      if [ "$(tmx list-windows -t "$SESSION" | wc -l | tr -d ' ')" -gt 1 ]; then
        target="$(random_window)"
        tmx kill-window -t "$target" >/dev/null 2>&1 || true
      fi
      ;;
    3)
      target="$(random_window)"
      tmx select-window -t "$target" >/dev/null 2>&1 || true
      ;;
    4)
      target="$(random_window)"
      pane="$(content_pane "$target")"
      if [ -n "$pane" ]; then
        tmx send-keys -t "$pane" "echo FUZZ_${RANDOM}" Enter >/dev/null 2>&1 || true
      fi
      ;;
    5)
      target="$(random_window)"
      pane="$(content_pane "$target")"
      if [ -n "$pane" ]; then
        tmx split-window -d -t "$pane" -v -l 6 >/dev/null 2>&1 || true
      fi
      ;;
    6)
      if [ "$(content_pane_count)" -gt 1 ]; then
        target="$(random_window)"
        pane="$(content_pane "$target")"
      else
        pane=""
      fi
      if [ -n "$pane" ]; then
        tmx kill-pane -t "$pane" >/dev/null 2>&1 || true
      fi
      ;;
    7)
      if [ $((RANDOM % 2)) -eq 0 ]; then
        if ! set_mode enabled; then
          set_mode disabled || true
        fi
      else
        if ! set_mode disabled; then
          set_mode enabled || true
        fi
      fi
      ;;
  esac
}

tmx start-server
tmx new-session -d -s "$SESSION" -n "main"
export TABBY_TMUX_SOCKET
TABBY_TMUX_SOCKET="$(tmx display-message -p '#{socket_path}')"
TERM=xterm script -q -c "TERM=xterm tmux attach-session -t '$SESSION'" "/tmp/tabby-live-fuzz-attach-$$.typescript" >/tmp/tabby-live-fuzz-attach-$$.log 2>&1 &
CLIENT_PID=$!
wait_for 40 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' | grep -qx '$SESSION'"

tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full

if ! enable_sidebar; then
  echo "✗ failed to enter consistent enabled mode before fuzz run"
  exit 1
fi

RANDOM="$SEED"
echo "seed=$SEED steps=$STEPS"
for i in $(seq 1 "$STEPS"); do
  op=$((RANDOM % 8))
  run_op "$op"
  if ! wait_current_consistency; then
    echo "✗ consistency failed at step=$i op=$op seed=$SEED"
    echo "mode=$(mode_value)"
    tmx list-windows -t "$SESSION" -F "#{window_id}|#{window_index}|#{window_name}" || true
    tmx list-panes -s -t "$SESSION" -F "#{window_id}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
    exit 1
  fi
done

if [ "$(tmx list-windows -t "$SESSION" | wc -l | tr -d ' ')" -lt 1 ]; then
  echo "✗ no windows left after fuzz"
  exit 1
fi

echo "=== Live seeded fuzz trajectory test passed ==="
