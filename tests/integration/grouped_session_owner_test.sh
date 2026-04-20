#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: grouped sessions share one Tabby owner ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
source "$PROJECT_ROOT/tests/lib/live_tmux_test_lib.sh"
source "$PROJECT_ROOT/scripts/_tmux_socket_env.sh"

unset TABBY_TMUX_SOCKET TABBY_RUNTIME_PREFIX TABBY_TMUX_WRAPPED
tabby_live_require_tmux

if [ ! -x "$PROJECT_ROOT/bin/tabby-daemon" ] || [ ! -x "$PROJECT_ROOT/bin/sidebar-renderer" ]; then
    (cd "$PROJECT_ROOT" && make build >/dev/null)
fi

TABBY_LIVE_SOCKET="tabby-grouped-owner-$$"
export TABBY_LIVE_SOCKET

runtime_prefix=""
owner_id=""
sibling_id=""

cleanup() {
    local pid_file pid
    tabby_live_stop_clients
    if [ -n "$runtime_prefix" ]; then
        for pid_file in /tmp/${runtime_prefix}tabby-daemon-*.pid /tmp/${runtime_prefix}tabby-daemon-*.watchdog.pid; do
            [ -f "$pid_file" ] || continue
            pid="$(cat "$pid_file" 2>/dev/null || true)"
            [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
        done
        rm -f /tmp/${runtime_prefix}tabby-daemon-* /tmp/${runtime_prefix}tabby-sidebar-* /tmp/${runtime_prefix}tabby-toggle-* >/dev/null 2>&1 || true
    fi
    tabby_live_tmx kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for() {
    local tries="$1"
    shift
    local i
    for i in $(seq 1 "$tries"); do
        if "$@"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

daemon_pid_file_count() {
    find /tmp -maxdepth 1 -name "${runtime_prefix}tabby-daemon-*.pid" ! -name '*.watchdog.pid' 2>/dev/null | wc -l | tr -d ' '
}

renderer_count_for_window() {
    local target="$1"
    tabby_live_tmx list-panes -t "$target" -F '#{pane_current_command}|#{pane_start_command}' 2>/dev/null \
        | awk -F'|' '$1 ~ /(sidebar|sidebar-renderer)/ || $2 ~ /(sidebar|sidebar-renderer)/ { count++ } END { print count + 0 }'
}

renderer_count_is_one() {
    [ "$(renderer_count_for_window "$1")" = "1" ]
}

tabby_live_tmx start-server
tabby_live_tmx new-session -d -s grouped-owner -n main
tabby_live_tmx new-window -t grouped-owner: -n second
tabby_live_tmx new-session -d -t grouped-owner -s grouped-sibling
tabby_live_seed_env

runtime_prefix="$(tabby_runtime_prefix_for_socket "$TABBY_TMUX_SOCKET")"
owner_id="$(tabby_live_tmx display-message -p -t grouped-owner: '#{session_id}')"
sibling_id="$(tabby_live_tmx display-message -p -t grouped-sibling: '#{session_id}')"

canonical_for_sibling="$(
    PATH="$PROJECT_ROOT/bin:$PATH"
    export PATH TABBY_TMUX_SOCKET TABBY_TMUX_REAL
    source "$PROJECT_ROOT/scripts/_session_owner.sh"
    tabby_canonical_session_id "$sibling_id"
)"

if [ "$canonical_for_sibling" != "$owner_id" ]; then
    echo "✗ grouped sibling canonical owner mismatch: got $canonical_for_sibling want $owner_id"
    exit 1
fi

tabby_live_start_attached_client grouped-sibling grouped-owner-sibling
canonical_for_attached_sibling="$(
    PATH="$PROJECT_ROOT/bin:$PATH"
    export PATH TABBY_TMUX_SOCKET TABBY_TMUX_REAL
    source "$PROJECT_ROOT/scripts/_session_owner.sh"
    tabby_canonical_session_id "$sibling_id"
)"

if [ "$canonical_for_attached_sibling" != "$owner_id" ]; then
    echo "✗ attached grouped sibling changed canonical owner: got $canonical_for_attached_sibling want $owner_id"
    exit 1
fi

tabby_live_tmx set-option -g @tabby_sidebar enabled
tabby_live_tmx set-option -g @tabby_sidebar_width 20
tabby_live_tmx run-shell -b -t grouped-sibling: "$PROJECT_ROOT/scripts/ensure_sidebar.sh"

if ! wait_for 60 test -f "/tmp/${runtime_prefix}tabby-daemon-${owner_id}.pid"; then
    echo "✗ owner daemon pid file was not created"
    exit 1
fi

if [ -e "/tmp/${runtime_prefix}tabby-daemon-${sibling_id}.pid" ]; then
    echo "✗ non-owner grouped sibling got its own daemon pid file"
    exit 1
fi

tabby_live_tmx run-shell -b -t grouped-sibling: "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
tabby_live_tmx run-shell -b -t grouped-owner: "$PROJECT_ROOT/scripts/ensure_sidebar.sh"

pid_count="$(daemon_pid_file_count)"
if [ "$pid_count" != "1" ]; then
    echo "✗ expected one daemon pid file for grouped sessions, found $pid_count"
    find /tmp -maxdepth 1 -name "${runtime_prefix}tabby-daemon-*.pid" -print
    exit 1
fi

for window_id in $(tabby_live_tmx list-windows -t grouped-owner -F '#{window_id}'); do
    if ! wait_for 40 renderer_count_is_one "$window_id"; then
        count="$(renderer_count_for_window "$window_id")"
        echo "✗ expected one renderer in shared window $window_id, found $count"
        tabby_live_tmx list-panes -t "$window_id" -F '#{pane_id}|#{pane_current_command}|#{pane_start_command}'
        exit 1
    fi
done

echo "✓ grouped sessions share one canonical Tabby owner"
