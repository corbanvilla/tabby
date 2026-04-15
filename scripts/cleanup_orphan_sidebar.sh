#!/usr/bin/env bash
set -eu

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$CURRENT_DIR"

SESSION_ID="${1:-}"
WINDOW_ID="${2:-}"
RUNTIME_PREFIX="${TABBY_RUNTIME_PREFIX:-}"

if [ -z "$SESSION_ID" ]; then
    SESSION_ID=$(tmux display-message -p '#{session_id}' 2>/dev/null || echo "")
fi

if [ -z "$WINDOW_ID" ]; then
    WINDOW_ID=$(tmux display-message -p '#{window_id}' 2>/dev/null || echo "")
fi

signal_daemon() {
    if [ -n "$SESSION_ID" ]; then
        DAEMON_PID_FILE="/tmp/${RUNTIME_PREFIX}tabby-daemon-${SESSION_ID}.pid"
        if [ -f "$DAEMON_PID_FILE" ]; then
            PID="$(cat "$DAEMON_PID_FILE" 2>/dev/null || true)"
            [ -n "$PID" ] && kill -USR1 "$PID" 2>/dev/null || true
        fi
    fi
}

pick_replacement_window() {
    local target_window="$1"
    local target_index
    target_index=$(tmux display-message -p -t "$target_window" '#{window_index}' 2>/dev/null || echo "")

    tmux list-windows -t "$SESSION_ID" -F "#{window_index}|#{window_id}" 2>/dev/null | awk -F'|' -v target="$target_window" -v idx="$target_index" '
        $2 == target { next }
        idx ~ /^[0-9]+$/ {
            if ($1 < idx && ($1 > best_above_idx || best_above_idx == "")) {
                best_above_idx = $1
                best_above_id = $2
            }
            if ($1 > idx && ($1 < best_below_idx || best_below_idx == "")) {
                best_below_idx = $1
                best_below_id = $2
            }
            next
        }
        first_id == "" { first_id = $2 }
        END {
            if (best_above_id != "") {
                print best_above_id
            } else if (best_below_id != "") {
                print best_below_id
            } else if (first_id != "") {
                print first_id
            }
        }
    '
}

focus_replacement_window() {
    local target_window="$1"
    local current_window replacement_window

    current_window=$(tmux display-message -p '#{window_id}' 2>/dev/null || echo "")
    [ -n "$current_window" ] && [ "$current_window" = "$target_window" ] || return 0

    replacement_window="$(pick_replacement_window "$target_window")"
    [ -n "$replacement_window" ] || return 0

    tmux select-window -t "$replacement_window" 2>/dev/null || true
}

cleanup_window_if_orphan() {
    local target_window="$1"
    [ -z "$target_window" ] && return 0
    local pending_new
    pending_new=$(tmux show-option -gqv @tabby_new_window_id 2>/dev/null || echo "")

    for _ in $(seq 1 40); do
        local panes
        panes=$(tmux list-panes -t "$target_window" -F "#{pane_dead}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null || true)
        [ -z "$panes" ] && return 0

        local main_panes
        main_panes=$(printf "%s\n" "$panes" | awk -F'|' '
            $1 != "1" {
                cmd = $2 " " $3
                if (cmd !~ /(sidebar|sidebar-renderer|pane-header)/) {
                    count++
                }
            }
            END { print count+0 }
        ')

        if [ "$main_panes" -eq 0 ]; then
            local session_window_count
            session_window_count=$(tmux list-windows -t "$SESSION_ID" 2>/dev/null | wc -l | tr -d ' ')
            if [ "${session_window_count:-0}" -le 1 ]; then
                tmux kill-session -t "$SESSION_ID" 2>/dev/null || true
                signal_daemon
                return 0
            fi
            if [ -n "$pending_new" ] && [ "$pending_new" = "$target_window" ]; then
                tmux set-option -gu @tabby_new_window_id 2>/dev/null || true
            fi
            focus_replacement_window "$target_window"
            tmux kill-window -t "$target_window" 2>/dev/null || true
            # Signal daemon immediately after kill so the tab vanishes without waiting
            # for the rest of this script. The daemon's cleanupOrphanWindowsByTmux
            # handles any remaining orphans in other windows on the same refresh cycle.
            signal_daemon
            return 0
        fi

        sleep 0.05
    done
}

if [ -n "$WINDOW_ID" ]; then
    cleanup_window_if_orphan "$WINDOW_ID"
fi

if [ -n "$SESSION_ID" ]; then
    while IFS= read -r sibling_window; do
        [ -z "$sibling_window" ] && continue
        [ "$sibling_window" = "$WINDOW_ID" ] && continue
        cleanup_window_if_orphan "$sibling_window"
    done < <(tmux list-windows -t "$SESSION_ID" -F "#{window_id}" 2>/dev/null || true)
fi
