#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-window-death"
TEST_SESSION="tabby-window-death"

cleanup() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    tabby_cleanup_tmux_test_env
}
trap cleanup EXIT

tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
tmux new-session -d -s "$TEST_SESSION" -n "main"
tmux set-option -t "$TEST_SESSION" allow-rename off
tmux set-option -t "$TEST_SESSION" automatic-rename off
tmux run-shell -t "$TEST_SESSION" "$PROJECT_ROOT/tabby.tmux"
sleep 1

echo "Testing for window death issues..."

initial_windows=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id} #{window_index} #{window_name}")
echo "Initial windows:"
echo "$initial_windows"
echo ""

echo "Test 1: Creating new window..."
tmux new-window -t "$TEST_SESSION" -n "test-death"
sleep 0.5

echo "Test 2: Switching to new window..."
tmux select-window -t "$TEST_SESSION:test-death"
sleep 0.5

echo "Test 3: Toggling sidebar..."
tmux run-shell -t "$TEST_SESSION" "$PROJECT_ROOT/scripts/toggle_sidebar.sh"
sleep 1

echo "Test 4: Switching back to original window..."
tmux select-window -t "$TEST_SESSION:0"
sleep 0.5

echo "Test 5: Checking if test window still exists..."
if tmux list-windows -t "$TEST_SESSION" | grep -q "test-death"; then
    echo "✓ Window survived sidebar toggle"
else
    echo "✗ Window died during sidebar toggle!"
fi

echo ""
echo "Final windows:"
tmux list-windows -t "$TEST_SESSION" -F "#{window_id} #{window_index} #{window_name}"

echo ""
echo "Test 6: Cleaning up test window..."
tmux kill-window -t "$TEST_SESSION:test-death" 2>/dev/null || true
