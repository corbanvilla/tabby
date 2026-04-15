#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Terminal resize convergence ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
source "$PROJECT_ROOT/tests/lib/live_tmux_test_lib.sh"

TABBY_LIVE_SOCKET="tabby-terminal-resize-$$"
SESSION="terminal-resize"
TABBY_LIVE_CLIENT_PIDS=""

cleanup() {
    tabby_live_stop_clients
    tabby_live_tmx kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

tabby_live_require_tmux

assert_equals() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "✓ $description"
    else
        echo "✗ $description: expected=$expected actual=$actual"
        exit 1
    fi
}

sidebar_width_equals() {
    local target="$1"
    local expected="$2"
    [ "$(tabby_live_sidebar_width_for_window "$target")" = "$expected" ]
}

content_width_at_least() {
    local target="$1"
    local min_width="$2"
    local width
    width="$(tabby_live_content_width_for_window "$target")"
    [ -n "$width" ] && [ "$width" -ge "$min_width" ]
}

echo "Bootstrapping isolated tmux server..."
tabby_live_tmx start-server
tabby_live_tmx new-session -d -s "$SESSION" -n "main"
tabby_live_seed_env
tabby_live_start_attached_client "$SESSION" "terminal-resize"
tabby_live_tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

tabby_live_tmx set-option -g @tabby_sidebar_position left
tabby_live_tmx set-option -g @tabby_sidebar_mode full
tabby_live_tmx set-option -g @tabby_sidebar_width_tablet 20
tabby_live_tmx set-option -g @tabby_sidebar_width_mobile 15

if ! tabby_live_enable_sidebar_for_session "$SESSION"; then
    echo "✗ failed to enable sidebar"
    exit 1
fi

client_tty="$(tabby_live_client_tty)"
if [ -z "$client_tty" ]; then
    echo "✗ failed to locate attached client tty"
    exit 1
fi

resize_and_assert() {
    local size="$1"
    local expected_sidebar="$2"
    local min_content="$3"
    tabby_live_resize_client "$client_tty" "$size"
    if ! tabby_live_wait_for 40 sidebar_width_equals "$SESSION:0" "$expected_sidebar"; then
        echo "✗ sidebar did not converge to width $expected_sidebar after client resize to $size"
        tabby_live_tmx list-panes -t "$SESSION:0" -F "#{pane_id}|#{pane_width}|#{pane_current_command}|#{pane_start_command}" || true
        exit 1
    fi
    if ! tabby_live_wait_for 40 content_width_at_least "$SESSION:0" "$min_content"; then
        echo "✗ content pane shrank below $min_content columns after resize to $size"
        tabby_live_tmx list-panes -t "$SESSION:0" -F "#{pane_id}|#{pane_width}|#{pane_current_command}|#{pane_start_command}" || true
        exit 1
    fi
    assert_equals "renderer count stayed stable for $size" "1" "$(tabby_live_renderer_count_for_window "$SESSION:0")"
}

tabby_live_resize_client "$client_tty" "190x45" "$SESSION:0"
sleep 0.5
desktop_width="$(tabby_live_sidebar_width_for_window "$SESSION:0")"
if [ -z "$desktop_width" ]; then
    echo "✗ failed to capture initial desktop sidebar width"
    exit 1
fi

resize_and_assert "190x45" "$desktop_width" "100"
resize_and_assert "150x45" "20" "90"
resize_and_assert "100x40" "15" "40"
resize_and_assert "190x45" "$desktop_width" "100"

echo "=== Terminal resize convergence test passed ==="
