#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Idle sidebar does not render-flood ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux)"
if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
  (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

SOCKET="tabby-idle-render-$$"
SOCKET_PATH="/tmp/tmux-$(id -u)/$SOCKET"
SESSION="tabby-idle-render"
TEST_HOME="$(mktemp -d)"
TEST_XDG="$TEST_HOME/.config"
PREFIX="sock-$(printf '%s' "$SOCKET_PATH" | cksum | awk '{print $1}')-"
LOG="/tmp/${PREFIX}tabby-daemon-\$0-events.log"

mkdir -p "$TEST_XDG/tabby"
cat >"$TEST_XDG/tabby/config.yaml" <<'YAML'
theme: default
sidebar:
  colors:
    active_indicator_frames: ["A", "B", " "]
widgets:
  clock:
    enabled: false
  stats:
    enabled: false
  pet:
    enabled: false
  git:
    enabled: false
  session:
    enabled: false
YAML

tmx() {
  env -u TMUX \
    HOME="$TEST_HOME" \
    XDG_CONFIG_HOME="$TEST_XDG" \
    TABBY_TMUX_REAL="$tmux_real" \
    TABBY_TMUX_SOCKET="$SOCKET_PATH" \
    "$tmux_real" -L "$SOCKET" -f /dev/null "$@"
}

cleanup() {
  tmx kill-server >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME" >/dev/null 2>&1 || true
  rm -f /tmp/${PREFIX}tabby-daemon-* >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_sidebar() {
  local i
  for i in $(seq 1 40); do
    if tmx list-panes -s -F '#{pane_current_command}' 2>/dev/null | grep -qx 'sidebar-renderer'; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

count_targeted_renders() {
  if [ ! -f "$LOG" ]; then
    printf '0'
    return
  fi
  grep -c 'TARGETED_RENDER' "$LOG" || true
}

rm -f /tmp/${PREFIX}tabby-daemon-* >/dev/null 2>&1 || true
tmx start-server
tmx new-session -d -s "$SESSION" -n idle 'exec bash -l'
tmx set-environment -g TABBY_TMUX_REAL "$tmux_real"
tmx set-environment -g TABBY_TMUX_SOCKET "$SOCKET_PATH"

env -u TMUX \
  HOME="$TEST_HOME" \
  XDG_CONFIG_HOME="$TEST_XDG" \
  TABBY_TMUX_REAL="$tmux_real" \
  TABBY_TMUX_SOCKET="$SOCKET_PATH" \
  TABBY_RUNTIME_PREFIX="$PREFIX" \
  PATH="$PROJECT_ROOT/bin:$PATH" \
  "$PROJECT_ROOT/scripts/toggle_sidebar.sh" >/dev/null

if ! wait_for_sidebar; then
  echo "sidebar renderer did not appear"
  tmx list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_start_command}' || true
  exit 1
fi

# Let startup refreshes and the first window-check settle before sampling.
sleep 3.5
before="$(count_targeted_renders)"
sleep 1.5
after="$(count_targeted_renders)"
delta=$((after - before))

if [ "$delta" -gt 3 ]; then
  echo "idle sidebar rendered too often: targeted render delta=$delta"
  tail -120 "$LOG" 2>/dev/null || true
  exit 1
fi

echo "✓ idle targeted render delta=$delta"
echo "=== Idle sidebar render flood test passed ==="
