#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: AI Indicator State Transitions ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-ai-indicator"
SET_IND="$PROJECT_ROOT/scripts/set-tabby-indicator.sh"
SESSION_NAME="ai-indicator-state-$$"

tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
tmux new-session -d -s "$SESSION_NAME" -n "main"

WIN_IDX="$(tmux display-message -t "$SESSION_NAME:0" -p '#{window_index}')"
PANE_ID="$(tmux display-message -t "$SESSION_NAME:0.0" -p '#{pane_id}')"

cleanup() {
  tmux set-option -w -t ":$WIN_IDX" -u @tabby_busy 2>/dev/null || true
  tmux set-option -w -t ":$WIN_IDX" -u @tabby_input 2>/dev/null || true
  tmux set-option -w -t ":$WIN_IDX" -u @tabby_bell 2>/dev/null || true
  tmux set-option -p -t "$PANE_ID" -u @tabby_bell 2>/dev/null || true
  tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  tabby_cleanup_tmux_test_env
}
trap cleanup EXIT

tmux set-option -w -t ":$WIN_IDX" -u @tabby_busy 2>/dev/null || true
tmux set-option -w -t ":$WIN_IDX" -u @tabby_input 2>/dev/null || true
tmux set-option -w -t ":$WIN_IDX" -u @tabby_bell 2>/dev/null || true
tmux set-option -p -t "$PANE_ID" -u @tabby_bell 2>/dev/null || true

TMUX_PANE="$PANE_ID" "$SET_IND" busy 1
BUSY_VAL="$(tmux show-window-options -t ":$WIN_IDX" -v @tabby_busy 2>/dev/null || true)"
if [ "$BUSY_VAL" != "1" ]; then
  echo "✗ busy 1 did not set @tabby_busy on window $WIN_IDX"
  exit 1
fi

TMUX_PANE="$PANE_ID" "$SET_IND" busy 0
BUSY_CLEARED="$(tmux show-window-options -t ":$WIN_IDX" -v @tabby_busy 2>/dev/null || true)"
if [ -n "$BUSY_CLEARED" ]; then
  echo "✗ busy 0 did not clear @tabby_busy on window $WIN_IDX"
  exit 1
fi

TMUX_PANE="$PANE_ID" "$SET_IND" input 1
INPUT_VAL="$(tmux show-window-options -t ":$WIN_IDX" -v @tabby_input 2>/dev/null || true)"
if [ "$INPUT_VAL" != "1" ]; then
  echo "✗ input 1 did not set @tabby_input on window $WIN_IDX"
  exit 1
fi

TMUX_PANE="$PANE_ID" "$SET_IND" input 0
INPUT_CLEARED="$(tmux show-window-options -t ":$WIN_IDX" -v @tabby_input 2>/dev/null || true)"
if [ -n "$INPUT_CLEARED" ]; then
  echo "✗ input 0 did not clear @tabby_input on window $WIN_IDX"
  exit 1
fi

TMUX_PANE="$PANE_ID" "$SET_IND" bell 1
BELL_VAL="$(tmux show-options -p -t "$PANE_ID" -v @tabby_bell 2>/dev/null || true)"
if [ "$BELL_VAL" != "1" ]; then
  echo "✗ bell 1 did not set @tabby_bell on pane $PANE_ID"
  exit 1
fi

echo "✓ busy/input/bell transitions apply correctly on current pane/window"
echo "=== AI indicator state transition test passed ==="
