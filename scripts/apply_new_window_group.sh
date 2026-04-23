#!/usr/bin/env bash
# Apply saved group to newly created window
set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$CURRENT_DIR/scripts/_tmux_socket_env.sh" ]; then
    source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
    tabby_init_tmux_socket_env "$CURRENT_DIR"
fi

initial_window_name_for_group() {
    local group="$1"
    group="$(printf "%s" "$group" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -z "$group" ] || [ "$group" = "Default" ]; then
        return 0
    fi
    printf "%s|\n" "$group"
}

SAVED_GROUP=$(tmux show-option -gqv @tabby_new_window_group 2>/dev/null || echo "")
NEW_WINDOW_ID="${1:-}"
if [ -z "$NEW_WINDOW_ID" ]; then
    NEW_WINDOW_ID=$(tmux show-option -gqv @tabby_new_window_id 2>/dev/null || echo "")
fi
if [ -z "$NEW_WINDOW_ID" ]; then
    NEW_WINDOW_ID=$(tmux display-message -p "#{window_id}" 2>/dev/null || echo "")
fi

if [ -n "$SAVED_GROUP" ] && [ -n "$NEW_WINDOW_ID" ]; then
    if [ "$SAVED_GROUP" != "Default" ]; then
        tmux set-window-option -t "$NEW_WINDOW_ID" @tabby_group "$SAVED_GROUP" 2>/dev/null || true
        INITIAL_NAME=$(initial_window_name_for_group "$SAVED_GROUP")
        if [ -n "$INITIAL_NAME" ]; then
            tmux rename-window -t "$NEW_WINDOW_ID" "$INITIAL_NAME" 2>/dev/null || true
            tmux set-window-option -t "$NEW_WINDOW_ID" @tabby_name_locked 1 2>/dev/null || true
        fi
    fi
    tmux set-option -gu @tabby_new_window_group 2>/dev/null || true
fi

exit 0
