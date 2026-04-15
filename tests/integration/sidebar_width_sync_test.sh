#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Sidebar width sync ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
source "$PROJECT_ROOT/tests/lib/live_tmux_test_lib.sh"

TABBY_LIVE_SOCKET="tabby-sidebar-width-sync-$$"
SESSION="sidebar-width-sync"
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

global_width_equals() {
    local expected="$1"
    [ "$(tabby_live_tmx show-options -gqv @tabby_sidebar_width)" = "$expected" ]
}

window_width_equals() {
    local target="$1"
    local expected="$2"
    [ "$(tabby_live_sidebar_width_for_window "$target")" = "$expected" ]
}

window_widths_match() {
    local left="$1"
    local right="$2"
    [ "$(tabby_live_sidebar_width_for_window "$left")" = "$(tabby_live_sidebar_width_for_window "$right")" ]
}

echo "Bootstrapping isolated tmux server..."
tabby_live_tmx start-server
tabby_live_tmx new-session -d -s "$SESSION" -n "main"
tabby_live_seed_env
tabby_live_start_attached_client "$SESSION" "sidebar-width-sync"
tabby_live_tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

tabby_live_tmx set-option -g @tabby_sidebar_position left
tabby_live_tmx set-option -g @tabby_sidebar_mode full
tabby_live_tmx set-option -g @tabby_sidebar_width 30
tabby_live_tmx set-option -g @tabby_sidebar_width_desktop 30
tabby_live_tmx set-option -g @tabby_sidebar_width_tablet 20
tabby_live_tmx set-option -g @tabby_sidebar_width_mobile 15

if ! tabby_live_enable_sidebar_for_session "$SESSION"; then
    echo "✗ failed to enable sidebar in base session"
    exit 1
fi

tabby_live_tmx resize-window -t "$SESSION:0" -x 220 -y 50
win2="$(tabby_live_tmx new-window -P -F "#{window_id}" -t "$SESSION:" -n "peer")"
tabby_live_tmx select-window -t "$win2"
tabby_live_tmx resize-window -t "$win2" -x 220 -y 50

if ! tabby_live_enable_sidebar_for_window "$SESSION" "$win2"; then
    echo "✗ failed to attach sidebar to peer window"
    exit 1
fi

tabby_live_tmx select-window -t "$SESSION:0"
tabby_live_tmx run-shell -b "$PROJECT_ROOT/scripts/resize_sidebar.sh"
if ! tabby_live_wait_for 40 window_widths_match "$SESSION:0" "$win2"; then
    echo "✗ initial sidebars did not converge to the same width"
    tabby_live_tmx list-panes -a -F "#{window_id}|#{pane_id}|#{pane_width}|#{pane_current_command}|#{pane_start_command}" || true
    exit 1
fi

tabby_live_tmx set-option -g @tabby_sidebar_width 34
tabby_live_tmx set-option -g @tabby_sidebar_width_desktop 34
tabby_live_tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
sleep 1
tabby_live_tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"

if ! tabby_live_wait_for 40 global_width_equals 34; then
    echo "✗ sidebar width option did not update to 34"
    exit 1
fi

if ! tabby_live_enable_sidebar_for_session "$SESSION" || ! tabby_live_enable_sidebar_for_window "$SESSION" "$win2"; then
    echo "✗ sidebar failed to restart after width change"
    exit 1
fi
tabby_live_tmx select-window -t "$win2"
if ! tabby_live_enable_sidebar_for_window "$SESSION" "$win2"; then
    echo "✗ peer window did not recover its renderer after restart"
    exit 1
fi
tabby_live_tmx select-window -t "$SESSION:0"

if ! tabby_live_wait_for 40 window_width_equals "$SESSION:0" 34 || ! tabby_live_wait_for 40 window_width_equals "$win2" 34; then
    echo "✗ sidebars did not converge to resized width"
    tabby_live_tmx list-panes -a -F "#{window_id}|#{pane_id}|#{pane_width}|#{pane_current_command}|#{pane_start_command}" || true
    exit 1
fi

assert_equals "global sidebar width updated" "34" "$(tabby_live_tmx show-options -gqv @tabby_sidebar_width)"
assert_equals "desktop width profile updated" "34" "$(tabby_live_tmx show-options -gqv @tabby_sidebar_width_desktop)"
assert_equals "main window kept one renderer" "1" "$(tabby_live_renderer_count_for_window "$SESSION:0")"
assert_equals "peer window kept one renderer" "1" "$(tabby_live_renderer_count_for_window "$win2")"

echo "=== Sidebar width sync test passed ==="
