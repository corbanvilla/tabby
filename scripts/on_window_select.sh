#!/usr/bin/env bash
# Handler for window selection - signal daemon and update border color

SPAWNING=$(tmux show-option -gqv @tabby_spawning 2>/dev/null || echo "")
if [ "$SPAWNING" = "1" ]; then
    exit 0
fi

# Clear bell indicators when user switches to a window.
# Input is only acknowledged when the specific pane is focused.
tmux set-option -w @tabby_bell "" 2>/dev/null || true

# Re-entering a window does not trigger after-select-pane when the same content
# pane remains active, so acknowledge input-needed on that focused pane here too.
ACTIVE_CMD=$(tmux display-message -p '#{pane_current_command}' 2>/dev/null || echo "")
ACTIVE_START=$(tmux display-message -p '#{pane_start_command}' 2>/dev/null || echo "")
case "$ACTIVE_CMD $ACTIVE_START" in
    *sidebar-renderer*|*pane-header*)
        ;;
    *)
        tmux set-option -p @tabby_input_ack 1 2>/dev/null || true
        ;;
esac

# Signal daemon to refresh immediately (daemon handles width sync)
DAEMON_PID_FILE="/tmp/tabby-daemon-$(tmux display-message -p '#{session_id}').pid"
[ -f "$DAEMON_PID_FILE" ] && kill -USR1 "$(cat "$DAEMON_PID_FILE")" 2>/dev/null || true

# Update pane border color if border_from_tab is enabled
BORDER_FROM_TAB=$(tmux show-option -gqv @tabby_border_from_tab)
if [ "$BORDER_FROM_TAB" = "true" ]; then
    # Get the window's tab bg color (set by sidebar via @tabby_pane_active)
    # Note: show-window-option returns quotes around values, so strip them
    TAB_BG=$(tmux show-window-option @tabby_pane_active 2>/dev/null | awk '{print $2}' | tr -d '"')

    # If no custom bg color, use the default
    if [ -z "$TAB_BG" ]; then
        TAB_BG=$(tmux show-option -gqv @tabby_pane_active_bg_default)
    fi

    # Get the tab fg color
    TAB_FG=$(tmux show-option -gqv @tabby_pane_active_fg)
    if [ -z "$TAB_FG" ]; then
        TAB_FG="#ffffff"
    fi

    # Set active border to tab color
    # pane-border-style (inactive) is set by cycle-pane --dim-only
    # which runs after this in the hook chain and desaturates the color
    if [ -n "$TAB_BG" ]; then
        tmux set-option -g pane-active-border-style "fg=$TAB_BG"
    fi
fi

# Always exit success
exit 0
