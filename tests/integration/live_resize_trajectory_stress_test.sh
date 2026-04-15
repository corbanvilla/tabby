#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live resize trajectory stress ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
source "$PROJECT_ROOT/tests/lib/live_tmux_test_lib.sh"

TABBY_LIVE_SOCKET="tabby-live-resize-stress-$$"
SESSION="resize-stress"
TABBY_LIVE_CLIENT_PIDS=""

cleanup() {
    tabby_live_stop_clients
    tabby_live_tmx kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

tabby_live_require_tmux

pane_contains() {
    local target="$1"
    local needle="$2"
    tabby_live_tmx capture-pane -t "$target" -p 2>/dev/null | grep -Fq "$needle"
}

window_invariants_hold() {
    local target="$1"
    local sidebar_width
    local renderer_count
    local content_count
    renderer_count="$(tabby_live_renderer_count_for_window "$target")"
    content_count="$(tabby_live_content_count_for_window "$target")"
    sidebar_width="$(tabby_live_sidebar_width_for_window "$target")"
    [ "$renderer_count" = "1" ] || return 1
    [ "$content_count" -ge 1 ] || return 1
    [ -n "$sidebar_width" ] || return 1
    [ "$sidebar_width" -ge 15 ] || return 1
    [ "$sidebar_width" -le 40 ] || return 1
}

echo "Bootstrapping isolated tmux server..."
tabby_live_tmx start-server
tabby_live_tmx new-session -d -s "$SESSION" -n "main"
tabby_live_seed_env
tabby_live_start_attached_client "$SESSION" "resize-stress"
tabby_live_tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
sleep 1

tabby_live_tmx set-option -g @tabby_sidebar_position left
tabby_live_tmx set-option -g @tabby_sidebar_mode full
tabby_live_tmx set-option -g @tabby_sidebar_width 30
tabby_live_tmx set-option -g @tabby_sidebar_width_desktop 30
tabby_live_tmx set-option -g @tabby_sidebar_width_tablet 20
tabby_live_tmx set-option -g @tabby_sidebar_width_mobile 15

if ! tabby_live_enable_sidebar_for_session "$SESSION"; then
    echo "✗ failed to enable sidebar in stress session"
    exit 1
fi

tabby_live_tmx resize-window -t "$SESSION:0" -x 190 -y 45
win2="$(tabby_live_tmx new-window -P -F "#{window_id}" -t "$SESSION:" -n "peer")"
tabby_live_tmx select-window -t "$win2"
tabby_live_tmx resize-window -t "$win2" -x 190 -y 45

if ! tabby_live_enable_sidebar_for_window "$SESSION" "$win2"; then
    echo "✗ failed to enable sidebar in peer window"
    exit 1
fi

client_tty="$(tabby_live_client_tty)"
if [ -z "$client_tty" ]; then
    echo "✗ failed to locate attached client tty"
    exit 1
fi

targets=("$SESSION:0" "$win2")
sizes=("190x45" "150x45" "100x40" "200x50" "150x45" "190x45")
sidebar_widths=(32 27 35 24 33 30)
round=1

for i in "${!sizes[@]}"; do
    target="${targets[$((i % ${#targets[@]}))]}"
    tabby_live_tmx select-window -t "$target"

    content_pane="$(tabby_live_content_pane_for_window "$target")"
    if [ -z "$content_pane" ]; then
        echo "✗ failed to locate content pane for $target during round $round"
        exit 1
    fi

    if [ "$(tabby_live_content_count_for_window "$target")" -lt 2 ]; then
        tabby_live_tmx split-window -t "$content_pane" -v -l 8
        sleep 0.2
    fi

    tabby_live_tmx set-option -g @tabby_sidebar_width "${sidebar_widths[$i]}"
    tabby_live_tmx set-option -g @tabby_sidebar_width_desktop "${sidebar_widths[$i]}"
    tabby_live_tmx run-shell -b "$PROJECT_ROOT/scripts/resize_sidebar.sh"

    tabby_live_resize_client "$client_tty" "${sizes[$i]}" "$target"
    sleep 0.2

    if [ $((round % 2)) -eq 0 ] && [ "$(tabby_live_content_count_for_window "$target")" -gt 1 ]; then
        last_pane="$(tabby_live_last_content_pane_for_window "$target")"
        if [ -n "$last_pane" ] && [ "$last_pane" != "$(tabby_live_content_pane_for_window "$target")" ]; then
            tabby_live_tmx kill-pane -t "$last_pane"
        fi
    fi

    content_pane="$(tabby_live_content_pane_for_window "$target")"
    nonce="RESIZE_STRESS_ROUND_${round}"
    tabby_live_tmx send-keys -t "$content_pane" "echo $nonce" Enter

    if ! tabby_live_wait_for 50 pane_contains "$content_pane" "$nonce"; then
        echo "✗ content pane lost usability in round $round"
        exit 1
    fi

    if ! tabby_live_wait_for 50 window_invariants_hold "$target" || ! tabby_live_wait_for 50 window_invariants_hold "${targets[0]}" || ! tabby_live_wait_for 50 window_invariants_hold "${targets[1]}"; then
        echo "✗ resize trajectory invariants failed in round $round"
        tabby_live_tmx list-panes -a -F "#{window_id}|#{pane_id}|#{pane_width}|#{pane_height}|#{pane_current_command}|#{pane_start_command}" || true
        exit 1
    fi

    echo "✓ round $round maintained sidebar/content invariants"
    round=$((round + 1))
done

echo "=== Live resize trajectory stress test passed ==="
