#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$CURRENT_DIR"

TARGET="${1:-}"
CURRENT_WINDOW_ID="${2:-$(tmux display-message -p '#{window_id}')}"
SESSION_ID="${3:-$(tmux display-message -p '#{session_id}')}"

if [ -z "$TARGET" ]; then
    echo "usage: swap_window.sh <target> [window_id] [session_id]" >&2
    exit 1
fi

restore_original_window() {
    [ -n "$CURRENT_WINDOW_ID" ] || return 0
    local session_target client_tty
    session_target="$(tmux display-message -p -t "$CURRENT_WINDOW_ID" '#{session_id}' 2>/dev/null || true)"
    if [ -n "$session_target" ]; then
        while IFS= read -r client_tty; do
            [ -n "$client_tty" ] || continue
            tmux switch-client -c "$client_tty" -t "$CURRENT_WINDOW_ID" >/dev/null 2>&1 || true
        done < <(tmux list-clients -t "$session_target" -F '#{client_tty}' 2>/dev/null || true)
    fi
    tmux switch-client -t "$CURRENT_WINDOW_ID" >/dev/null 2>&1 || \
        tmux select-window -t "$CURRENT_WINDOW_ID" >/dev/null 2>&1 || true
}

record_original_focus() {
    [ -n "$CURRENT_WINDOW_ID" ] || return 0
    local pane_id
    pane_id="$(tmux display-message -p -t "$CURRENT_WINDOW_ID" '#{pane_id}' 2>/dev/null || true)"
    tmux set-option -g @tabby_last_window "$CURRENT_WINDOW_ID" 2>/dev/null || true
    [ -n "$pane_id" ] && tmux set-option -g @tabby_last_pane "$pane_id" 2>/dev/null || true
}

restore_original_window_after_hooks() {
    (
        sleep 0.1
        restore_original_window
        sleep 0.4
        restore_original_window
        sleep 0.8
        restore_original_window
    ) >/dev/null 2>&1 &
}

resolve_target_window() {
    case "$TARGET" in
        :+*|:-*)
            local direction count current_index session_target lines ids idx pos next_pos
            direction="${TARGET:1:1}"
            count="${TARGET:2}"
            case "$count" in
                ''|*[!0-9]*) count=1 ;;
            esac

            current_index="$(tmux display-message -p -t "$CURRENT_WINDOW_ID" '#{window_index}' 2>/dev/null || true)"
            session_target="$(tmux display-message -p -t "$CURRENT_WINDOW_ID" '#{session_id}' 2>/dev/null || true)"
            [ -n "$current_index" ] && [ -n "$session_target" ] || return 1

            mapfile -t lines < <(tmux list-windows -t "$session_target:" -F '#{window_index} #{window_id}' 2>/dev/null | sort -n)
            [ "${#lines[@]}" -gt 0 ] || return 1

            ids=()
            pos=-1
            for idx in "${!lines[@]}"; do
                ids+=("${lines[$idx]#* }")
                if [ "${lines[$idx]%% *}" = "$current_index" ]; then
                    pos="$idx"
                fi
            done
            [ "$pos" -ge 0 ] || return 1

            if [ "$direction" = "+" ]; then
                next_pos=$(( (pos + count) % ${#ids[@]} ))
            else
                next_pos=$(( (pos - count) % ${#ids[@]} ))
                if [ "$next_pos" -lt 0 ]; then
                    next_pos=$(( next_pos + ${#ids[@]} ))
                fi
            fi
            printf '%s\n' "${ids[$next_pos]}"
            ;;
        *)
            printf '%s\n' "$TARGET"
            ;;
    esac
}

TARGET_WINDOW="$(resolve_target_window || true)"
if [ -z "$TARGET_WINDOW" ]; then
    echo "could not resolve target window: $TARGET" >&2
    exit 1
fi

tmux swap-window -s "$CURRENT_WINDOW_ID" -t "$TARGET_WINDOW"

record_original_focus
restore_original_window
"$CURRENT_DIR/scripts/signal_sidebar.sh" "$SESSION_ID" >/dev/null 2>&1 || true
"$CURRENT_DIR/scripts/refresh_status.sh" >/dev/null 2>&1 || true
record_original_focus
restore_original_window
restore_original_window_after_hooks
