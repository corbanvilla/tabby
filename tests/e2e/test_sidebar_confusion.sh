#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-sidebar-confusion"
TEST_SESSION="tabby-sidebar-confusion"

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

echo "Testing sidebar window tracking..."
echo ""

echo "Opening sidebar..."
tmux run-shell -t "$TEST_SESSION" "$PROJECT_ROOT/scripts/toggle_sidebar.sh"
sleep 1

SIDEBAR_PANE=$(tmux list-panes -t "$TEST_SESSION" -F "#{pane_current_command}|#{pane_id}" | grep "^sidebar" | cut -d'|' -f2)

if [ -z "$SIDEBAR_PANE" ]; then
    echo "ERROR: Could not find sidebar pane"
    exit 1
fi

echo "Creating test windows..."
tmux new-window -t "$TEST_SESSION:1" -n "sidebar-test-1"
tmux new-window -t "$TEST_SESSION:2" -n "sidebar-test-2"
tmux new-window -t "$TEST_SESSION:3" -n "sidebar-test-3"
sleep 1

echo "Initial sidebar content:"
tmux capture-pane -t "$SIDEBAR_PANE" -p | grep -E "^\s*(\[|>)" | head -20
echo ""

echo "Killing middle window (6)..."
tmux kill-window -t "$TEST_SESSION:2"
sleep 1

echo "Sidebar after kill (should show windows 5 and 7 renumbered to 5 and 6):"
tmux capture-pane -t "$SIDEBAR_PANE" -p | grep -E "^\s*(\[|>)" | head -20
echo ""

echo "Click simulation test - selecting window via sidebar..."
tmux send-keys -t "$SIDEBAR_PANE" "jjj" 
sleep 0.5
tmux send-keys -t "$SIDEBAR_PANE" "Enter"
sleep 0.5

echo "Current window after sidebar selection:"
tmux display-message -t "$TEST_SESSION" -p "Window: #{window_index} - #{window_name}"
echo ""

echo "Cleaning up..."
tmux kill-window -t "$TEST_SESSION:sidebar-test-1" 2>/dev/null || true
tmux kill-window -t "$TEST_SESSION:sidebar-test-3" 2>/dev/null || true
tmux run-shell -t "$TEST_SESSION" "$PROJECT_ROOT/scripts/toggle_sidebar.sh"
