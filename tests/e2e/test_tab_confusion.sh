#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-tab-confusion"
TEST_SESSION="tabby-tab-confusion"

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

echo "Testing for tab confusion issues..."
echo ""

echo "Creating test scenario..."
tmux new-window -t "$TEST_SESSION:1" -n "confusion-test-A"
tmux new-window -t "$TEST_SESSION:2" -n "confusion-test-B"
tmux new-window -t "$TEST_SESSION:3" -n "confusion-test-C"
sleep 0.5

echo "Initial state:"
tmux list-windows -F "#{window_index}: #{window_name} (ID: #{window_id})"
echo ""

echo "Render-status output:"
"$PROJECT_ROOT/bin/render-status" | sed 's/#\[[^]]*\]//g' | sed 's/[[:space:]]\+/ /g'
echo ""

echo "Test 1: Kill middle window..."
tmux kill-window -t "$TEST_SESSION:2"
sleep 0.5

echo "After killing window 3:"
tmux list-windows -F "#{window_index}: #{window_name} (ID: #{window_id})"
echo ""

echo "Render-status after kill:"
"$PROJECT_ROOT/bin/render-status" | sed 's/#\[[^]]*\]//g' | sed 's/[[:space:]]\+/ /g'
echo ""

echo "Test 2: Create new window (should take index 3)..."
tmux new-window -t "$TEST_SESSION" -n "confusion-test-D"
sleep 0.5

echo "After creating new window:"
tmux list-windows -F "#{window_index}: #{window_name} (ID: #{window_id})"
echo ""

echo "Render-status after new window:"
"$PROJECT_ROOT/bin/render-status" | sed 's/#\[[^]]*\]//g' | sed 's/[[:space:]]\+/ /g'
echo ""

echo "Test 3: Rename windows to check mapping..."
tmux rename-window -t "$TEST_SESSION:1" "renamed-A"
tmux rename-window -t "$TEST_SESSION:3" "renamed-C"
sleep 0.5

echo "After renaming:"
tmux list-windows -F "#{window_index}: #{window_name} (ID: #{window_id})"
echo ""

echo "Render-status after rename:"
"$PROJECT_ROOT/bin/render-status" | sed 's/#\[[^]]*\]//g' | sed 's/[[:space:]]\+/ /g'
echo ""

echo "Cleaning up..."
tmux kill-window -t "renamed-A" 2>/dev/null || true
tmux kill-window -t "confusion-test-D" 2>/dev/null || true
tmux kill-window -t "renamed-C" 2>/dev/null || true
