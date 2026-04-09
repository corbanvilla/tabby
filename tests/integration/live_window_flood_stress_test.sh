#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live Window Flood Stress ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
TMUX_REAL="$(command -v tmux || true)"

WINDOW_COUNT="${TABBY_STRESS_WINDOWS:-16}"
LINES_PER_WINDOW="${TABBY_STRESS_LINES_PER_WINDOW:-20}"
CHURN_ROUNDS="${TABBY_STRESS_CHURN_ROUNDS:-20}"

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

SOCKET="tabby-live-stress-$$"
SESSION="stress-live"
WRAPPER_DIR="$(mktemp -d /tmp/tabby-live-stress-tmux.XXXXXX)"
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

mode_value() {
  tmx show-options -gqv @tabby_sidebar 2>/dev/null || true
}

window_count() {
  tmx list-windows -t "$SESSION" 2>/dev/null | wc -l | tr -d ' '
}

count_renderers_total() {
  tmx list-panes -s -t "$SESSION" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | \
    awk -F'|' '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ { c++ } END { print c+0 }'
}

window_renderer_count() {
  local wid="$1"
  tmx list-panes -t "$wid" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | \
    awk -F'|' '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ { c++ } END { print c+0 }'
}

window_has_sidebar() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
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

enabled_has_renderers_for_all_windows() {
  local wins renderers wid rc
  wins="$(window_count)"
  renderers="$(count_renderers_total)"

  [ "$wins" -ge 1 ] || return 1
  [ "$renderers" -ge "$wins" ] || return 1

  while IFS= read -r wid; do
    [ -z "$wid" ] && continue
    rc="$(window_renderer_count "$wid")"
    [ "$rc" -ge 1 ] || return 1
  done < <(tmx list-windows -t "$SESSION" -F "#{window_id}")

  return 0
}

content_pane() {
  local target="$1"
  tmx list-panes -t "$target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null | \
    awk -F'|' '$2 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ && $3 !~ /(sidebar-renderer|sidebar|tabby-daemon|pane-header)/ { print $1; exit }'
}

pane_contains() {
  local pane="$1"
  local needle="$2"
  tmx capture-pane -t "$pane" -p 2>/dev/null | grep -Fq "$needle"
}

enable_sidebar() {
  local attempt
  for attempt in 1 2 3; do
    tmx set-option -g @tabby_sidebar disabled
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if wait_for 80 enabled_has_renderers_for_all_windows; then
      return 0
    fi
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    sleep 0.3
  done
  return 1
}

count_windows_without_renderer() {
  local missing=0 wid rc
  while IFS= read -r wid; do
    [ -z "$wid" ] && continue
    rc="$(window_renderer_count "$wid")"
    if [ "$rc" -lt 1 ]; then
      missing=$((missing + 1))
    fi
  done < <(tmx list-windows -t "$SESSION" -F "#{window_id}")
  echo "$missing"
}

count_extra_renderers() {
  local extras=0 wid rc
  while IFS= read -r wid; do
    [ -z "$wid" ] && continue
    rc="$(window_renderer_count "$wid")"
    if [ "$rc" -gt 1 ]; then
      extras=$((extras + rc - 1))
    fi
  done < <(tmx list-windows -t "$SESSION" -F "#{window_id}")
  echo "$extras"
}

echo "Bootstrapping isolated tmux server..."
tmx start-server
tmx new-session -d -s "$SESSION" -n "main"
export TABBY_TMUX_SOCKET
TABBY_TMUX_SOCKET="$(tmx display-message -p '#{socket_path}')"
TERM=xterm script -q -c "TERM=xterm tmux attach-session -t '$SESSION'" "/tmp/tabby-live-stress-attach-$$.typescript" >/tmp/tabby-live-stress-attach-$$.log 2>&1 &
CLIENT_PID=$!
wait_for 50 bash -lc "tmux -L '$SOCKET' -f /dev/null list-clients -F '#{session_name}' | grep -qx '$SESSION'"

tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1
tmx set-option -g @tabby_sidebar_position left
tmx set-option -g @tabby_sidebar_mode full

if ! enable_sidebar; then
  echo "✗ failed to enter consistent enabled mode"
  exit 1
fi

echo "Creating ${WINDOW_COUNT} windows with heavy content..."
for idx in $(seq 1 "$WINDOW_COUNT"); do
  wid="$(tmx new-window -d -P -F "#{window_id}" -t "$SESSION:" -n "stress-$idx")"
  pane="$(content_pane "$wid")"
  [ -n "$pane" ] || { echo "✗ no content pane for $wid"; exit 1; }

  for line in $(seq 1 "$LINES_PER_WINDOW"); do
    tmx send-keys -t "$pane" "printf 'STRESS W${idx} L${line} %080d\\n' $line" Enter
  done

  if ! ensure_window_sidebar "$wid"; then
    echo "✗ window $wid did not recover a sidebar renderer during create idx=$idx"
    echo "mode=$(mode_value)"
    tmx list-windows -t "$SESSION" -F "#{window_id}|#{window_index}|#{window_name}" || true
    tmx list-panes -s -t "$SESSION" -F "#{window_id}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
    exit 1
  fi

done

if ! wait_for 120 enabled_has_renderers_for_all_windows; then
  echo "✗ missing renderer(s) after window flood"
  echo "mode=$(mode_value)"
  tmx list-windows -t "$SESSION" -F "#{window_id}|#{window_index}|#{window_name}" || true
  tmx list-panes -s -t "$SESSION" -F "#{window_id}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
  exit 1
fi

echo "Verifying payload landed in random windows..."
for idx in 1 $((WINDOW_COUNT / 2)) "$WINDOW_COUNT"; do
  pane="$(content_pane "$SESSION:$idx")"
  [ -n "$pane" ] || { echo "✗ missing pane in window index $idx"; exit 1; }
  token="STRESS W${idx} L${LINES_PER_WINDOW}"
  if ! wait_for 40 pane_contains "$pane" "$token"; then
    echo "✗ missing expected token '$token' in $pane"
    exit 1
  fi
done

echo "Applying cross-window churn rounds: ${CHURN_ROUNDS}"
for r in $(seq 1 "$CHURN_ROUNDS"); do
  target_idx=$((r % (WINDOW_COUNT + 1)))
  [ "$target_idx" -eq 0 ] && target_idx=1
  pane="$(content_pane "$SESSION:$target_idx")"
  [ -n "$pane" ] || continue

  tmx send-keys -t "$pane" "echo CHURN_ROUND_${r}_WIN_${target_idx}" Enter

  if [ $((r % 3)) -eq 0 ]; then
    tmx rename-window -t "$SESSION:$target_idx" "stress-${target_idx}-r${r}" >/dev/null 2>&1 || true
  fi
  if [ $((r % 5)) -eq 0 ]; then
    tmx split-window -d -t "$pane" -v -l 6 >/dev/null 2>&1 || true
    extra_pane="$(content_pane "$SESSION:$target_idx")"
    [ -n "$extra_pane" ] && tmx send-keys -t "$extra_pane" "echo SPLIT_ROUND_${r}" Enter
    if [ -n "$extra_pane" ] && [ "$extra_pane" != "$pane" ]; then
      tmx kill-pane -t "$extra_pane" >/dev/null 2>&1 || true
    fi
  fi

  if ! ensure_window_sidebar "$SESSION:$target_idx"; then
    echo "✗ missing sidebar in churn round=$r window=$target_idx"
    tmx list-windows -t "$SESSION" -F "#{window_id}|#{window_index}|#{window_name}" || true
    tmx list-panes -s -t "$SESSION" -F "#{window_id}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
    exit 1
  fi
done

final_windows="$(window_count)"
final_renderers="$(count_renderers_total)"
missing_windows="$(count_windows_without_renderer)"
extra_renderers="$(count_extra_renderers)"

if [ "$final_windows" -lt "$WINDOW_COUNT" ]; then
  echo "✗ lost windows unexpectedly: expected >=$WINDOW_COUNT got $final_windows"
  exit 1
fi

if [ "$missing_windows" -ne 0 ]; then
  echo "✗ final windows missing renderer: missing_windows=$missing_windows"
  exit 1
fi

echo "windows=$final_windows renderers=$final_renderers extra_renderers=$extra_renderers mode=$(mode_value)"
echo "=== Live Window Flood Stress test passed ==="
