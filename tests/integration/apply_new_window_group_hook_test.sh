#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Apply New Window Group Hook ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-apply-group-hook"

TEST_SESSION="tabby-apply-group-hook-test"
APPLY_GROUP_SCRIPT="$PROJECT_ROOT/scripts/apply_new_window_group.sh"

cleanup() {
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  tabby_cleanup_tmux_test_env
}
trap cleanup EXIT

wait_for_group() {
  local window_id="$1"
  local expected="$2"
  local i group
  for i in $(seq 1 20); do
    group="$(tmux show-window-options -t "$window_id" -v @tabby_group 2>/dev/null || echo "")"
    if [ "$group" = "$expected" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
tmux new-session -d -s "$TEST_SESSION" -n "main"

tmux set-hook -g after-new-window "run-shell 'if [ -x \"$APPLY_GROUP_SCRIPT\" ]; then \"$APPLY_GROUP_SCRIPT\" \"#{window_id}\"; fi'"
tmux set-option -g @tabby_new_window_group "HookGroup"
tmux new-window -d -t "$TEST_SESSION:" -n "raw"

NEW_WINDOW_ID="$(tmux list-windows -t "$TEST_SESSION" -F '#{window_id}' | tail -1)"
if wait_for_group "$NEW_WINDOW_ID" "HookGroup"; then
  echo "✓ after-new-window hook applied @tabby_group"
else
  echo "✗ after-new-window hook did not apply @tabby_group" >&2
  tmux show-window-options -t "$NEW_WINDOW_ID" -v @tabby_group 2>/dev/null || true
  exit 1
fi

WINDOW_NAME="$(tmux display-message -p -t "$NEW_WINDOW_ID" '#{window_name}' 2>/dev/null || echo "")"
if [ "$WINDOW_NAME" = "HookGroup|" ]; then
  echo "✓ after-new-window hook applied initial grouped name"
else
  echo "✗ grouped window name is '$WINDOW_NAME', expected 'HookGroup|'" >&2
  exit 1
fi

PENDING_GROUP="$(tmux show-option -gqv @tabby_new_window_group 2>/dev/null || echo "")"
if [ -z "$PENDING_GROUP" ]; then
  echo "✓ after-new-window hook cleared pending group"
else
  echo "✗ @tabby_new_window_group still set to '$PENDING_GROUP'" >&2
  exit 1
fi

if tmux show-messages -JT 2>/dev/null | grep -Eq 'returned 127|apply_new_window_group.*returned'; then
  echo "✗ after-new-window hook produced command failure noise" >&2
  tmux show-messages -JT 2>/dev/null | grep -E 'returned 127|apply_new_window_group.*returned' >&2 || true
  exit 1
else
  echo "✓ after-new-window hook did not produce command failure noise"
fi

echo "=== Apply new window group hook test passed ==="
