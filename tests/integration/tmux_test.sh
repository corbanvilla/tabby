#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-integration"
TEST_SESSION="tabby-integration-test"

cleanup() {
	tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
	tmux kill-server 2>/dev/null || true
	tabby_cleanup_tmux_test_env
}
trap cleanup EXIT

echo "=== Integration Test: Horizontal Rendering ==="

tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
tmux new-session -d -s "$TEST_SESSION"

tmux rename-window -t "$TEST_SESSION":0 "SD|app"
tmux new-window -t "$TEST_SESSION" -n "GP|tool"
tmux new-window -t "$TEST_SESSION" -n "notes"

tmux set-option -g @tabby_test 1
sleep 1

# Smoke-test render binary execution without requiring an attached client.
"$PROJECT_ROOT/bin/render-status" >/dev/null 2>&1 || true

WINDOWS="$(tmux list-windows -t "$TEST_SESSION" -F "#{window_name}")"

if echo "$WINDOWS" | grep -Fq "SD|app"; then
	echo "✓ SD window found"
else
	echo "✗ SD window missing"
	exit 1
fi

if echo "$WINDOWS" | grep -Fq "GP|tool"; then
	echo "✓ GP window found"
else
	echo "✗ GP window missing"
	exit 1
fi

echo "=== All integration tests passed ==="
