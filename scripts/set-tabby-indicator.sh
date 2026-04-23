#!/bin/bash
# set-tabby-indicator.sh - Set tabby indicators on a tmux window or pane
# Usage: set-tabby-indicator.sh [busy|bell|activity|silence] [0|1]
#
# For busy=1 (UserPromptSubmit): Uses the currently focused pane since
# that's where the user just typed their message.
#
# For busy=0/bell=1 (Stop): Uses state files to track which windows
# were marked busy, since focus may have changed.
#
# Indicators:
#   busy     - Animated spinner (for long-running tasks)
#   bell     - Alert icon (task completed, needs attention)
#   activity - Activity marker (unseen output)
#   silence  - Silence marker (no output for a period)

INDICATOR="$1"
VALUE="$2"

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$CURRENT_DIR"
source "$CURRENT_DIR/scripts/_session_owner.sh"

# State directory for tracking which panes/windows were marked busy
STATE_DIR="/tmp/tabby-state"
mkdir -p "$STATE_DIR" 2>/dev/null

SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)

log_debug() {
    echo "=== $(date) ===" >> /tmp/tabby-indicator-debug.log
    echo "INDICATOR=$INDICATOR VALUE=$VALUE" >> /tmp/tabby-indicator-debug.log
    echo "$1" >> /tmp/tabby-indicator-debug.log
}

window_exists() {
    local win="$1"
    [ -n "$win" ] || return 1
    tmux list-windows -F '#{window_index}' 2>/dev/null | grep -qx "$win"
}

pane_exists() {
    local pane="$1"
    [ -n "$pane" ] || return 1
    tmux display-message -t "$pane" -p '#{pane_id}' >/dev/null 2>&1
}

resolve_window_from_pane() {
    local pane="$1"
    [ -n "$pane" ] || return 1
    tmux display-message -t "$pane" -p '#{window_index}' 2>/dev/null
}

resolve_window_from_state() {
    local win=""

    if [ -n "$SESSION" ] && [ -f "$STATE_DIR/last-${SESSION}" ]; then
        win=$(cat "$STATE_DIR/last-${SESSION}" 2>/dev/null || true)
        if window_exists "$win"; then
            echo "$win"
            return 0
        fi
    fi

    if [ -n "$SESSION" ]; then
        local newest
        newest=$(ls -t "$STATE_DIR"/busy-"${SESSION}"-* 2>/dev/null | head -n1 || true)
        if [ -n "$newest" ]; then
            win=${newest##*-}
            if window_exists "$win"; then
                echo "$win"
                return 0
            fi
        fi
    fi

    # Last-resort: infer from current tmux busy flags when hooks race/out-of-pane.
    win=$(tmux list-windows -F '#{window_index} #{@tabby_busy}' 2>/dev/null | awk '$2 != "" && $2 != "0" {print $1; exit}')
    if window_exists "$win"; then
        echo "$win"
        return 0
    fi

    return 1
}

resolve_pane_from_state() {
    local pane=""

    if [ -n "$SESSION" ] && [ -f "$STATE_DIR/last-pane-${SESSION}" ]; then
        pane=$(cat "$STATE_DIR/last-pane-${SESSION}" 2>/dev/null || true)
        if pane_exists "$pane"; then
            echo "$pane"
            return 0
        fi
    fi

    if [ -n "$SESSION" ]; then
        local newest
        newest=$(ls -t "$STATE_DIR"/busy-pane-"${SESSION}"-* 2>/dev/null | head -n1 || true)
        if [ -n "$newest" ]; then
            pane=${newest##*-}
            if pane_exists "$pane"; then
                echo "$pane"
                return 0
            fi
        fi
    fi

    return 1
}

# Get the window for this Claude session
# Strategy: Use TMUX_PANE if valid, otherwise try to find our parent's pane
CLAUDE_PANE=""
CLAUDE_WIN=""

# First, verify TMUX_PANE points to an existing pane
if [ -n "$TMUX_PANE" ]; then
    # Check if this pane still exists
    if tmux display-message -t "$TMUX_PANE" -p '#{pane_id}' &>/dev/null; then
        CLAUDE_PANE="$TMUX_PANE"
        CLAUDE_WIN=$(tmux display-message -t "$TMUX_PANE" -p '#{window_index}' 2>/dev/null)
    fi
fi

# Fallback: try to find pane by walking up process tree to find tmux client
if [ -z "$CLAUDE_WIN" ]; then
    # Get our parent PID chain and find which pane we're in
    CURRENT_PID=$$
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # Check if this PID is a tmux pane's shell
        FOUND_PANE_INFO=$(tmux list-panes -a -F '#{pane_pid}:#{pane_id}:#{window_index}' 2>/dev/null | grep "^${CURRENT_PID}:" | head -n1 || true)
        if [ -n "$FOUND_PANE_INFO" ]; then
            CLAUDE_PANE=$(printf '%s\n' "$FOUND_PANE_INFO" | cut -d: -f2)
            CLAUDE_WIN=$(printf '%s\n' "$FOUND_PANE_INFO" | cut -d: -f3)
            break
        fi
        # Move to parent
        CURRENT_PID=$(ps -o ppid= -p "$CURRENT_PID" 2>/dev/null | tr -d ' ')
        [ -z "$CURRENT_PID" ] && break
    done
fi

# Final fallback: use active window ONLY for busy=1 (UserPromptSubmit).
# For all other operations (busy=0, bell, input), the user may have switched
# windows since the hook was registered, so targeting the active window would
# set indicators on the WRONG window.
USED_FALLBACK=""
if [ -z "$CLAUDE_WIN" ]; then
    if [ "$INDICATOR" = "busy" ] && [ "$VALUE" = "1" ]; then
        CLAUDE_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
        CLAUDE_WIN=$(tmux display-message -p '#{window_index}' 2>/dev/null)
        USED_FALLBACK="active-window"
    else
        # Try robust state-based recovery for stop/question/done events.
        CLAUDE_PANE=$(resolve_pane_from_state || true)
        if [ -n "$CLAUDE_PANE" ]; then
            CLAUDE_WIN=$(resolve_window_from_pane "$CLAUDE_PANE" || true)
            USED_FALLBACK="state-recovery"
        else
            CLAUDE_WIN=$(resolve_window_from_state || true)
        fi
        if [ -n "$CLAUDE_WIN" ]; then
            USED_FALLBACK="state-recovery"
        else
            # Cannot determine correct window — skip rather than target wrong one
            log_debug "TMUX_PANE=$TMUX_PANE -> CLAUDE_PANE/CLAUDE_WIN=(none, skipping)"
            exit 0
        fi
    fi
fi

# Debug logging
log_debug "TMUX_PANE=$TMUX_PANE -> CLAUDE_PANE=$CLAUDE_PANE CLAUDE_WIN=$CLAUDE_WIN${USED_FALLBACK:+ (fallback: $USED_FALLBACK)}"

case "$INDICATOR" in
    busy)
        if [ "$VALUE" = "1" ]; then
            # Mark Claude's window as busy (derived from TMUX_PANE)
            if [ -n "$CLAUDE_WIN" ]; then
                touch "$STATE_DIR/busy-${SESSION}-${CLAUDE_WIN}"
                if [ -n "$CLAUDE_PANE" ]; then
                    touch "$STATE_DIR/busy-pane-${SESSION}-${CLAUDE_PANE}"
                    [ -n "$SESSION" ] && echo "$CLAUDE_PANE" > "$STATE_DIR/last-pane-${SESSION}"
                    tmux set-option -p -t "$CLAUDE_PANE" -u @tabby_input_ack 2>/dev/null
                fi
                [ -n "$SESSION" ] && echo "$CLAUDE_WIN" > "$STATE_DIR/last-${SESSION}"
                tmux set-option -t ":$CLAUDE_WIN" -w @tabby_busy 1 2>/dev/null
                [ -n "$CLAUDE_PANE" ] && tmux set-option -p -t "$CLAUDE_PANE" -u @tabby_bell 2>/dev/null
                tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_bell 2>/dev/null
                echo "Set busy on window $CLAUDE_WIN" >> /tmp/tabby-indicator-debug.log
            fi
        else
            # Clear busy ONLY on this Claude's window (not other windows)
            if [ -n "$CLAUDE_WIN" ]; then
                tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_busy 2>/dev/null
                rm -f "$STATE_DIR/busy-${SESSION}-${CLAUDE_WIN}" 2>/dev/null || true
                [ -n "$CLAUDE_PANE" ] && rm -f "$STATE_DIR/busy-pane-${SESSION}-${CLAUDE_PANE}" 2>/dev/null || true
                [ -n "$SESSION" ] && [ -n "$CLAUDE_PANE" ] && echo "$CLAUDE_PANE" > "$STATE_DIR/last-pane-${SESSION}"
                [ -n "$SESSION" ] && echo "$CLAUDE_WIN" > "$STATE_DIR/last-${SESSION}"
                echo "Cleared busy on window $CLAUDE_WIN" >> /tmp/tabby-indicator-debug.log
            fi
        fi
        ;;
    bell)
        if [ "$VALUE" = "1" ]; then
            # Set bell on the originating pane and clean up its busy state.
            if [ -n "$CLAUDE_WIN" ]; then
                STATE_FILE="$STATE_DIR/busy-${SESSION}-${CLAUDE_WIN}"
                tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_busy 2>/dev/null
                if [ -n "$CLAUDE_PANE" ]; then
                    tmux set-option -p -t "$CLAUDE_PANE" @tabby_bell 1 2>/dev/null
                    rm -f "$STATE_DIR/busy-pane-${SESSION}-${CLAUDE_PANE}" 2>/dev/null || true
                    [ -n "$SESSION" ] && echo "$CLAUDE_PANE" > "$STATE_DIR/last-pane-${SESSION}"
                else
                    tmux set-option -t ":$CLAUDE_WIN" -w @tabby_bell 1 2>/dev/null
                fi
                rm -f "$STATE_FILE" 2>/dev/null || true
                [ -n "$SESSION" ] && echo "$CLAUDE_WIN" > "$STATE_DIR/last-${SESSION}"
                echo "Set bell on pane ${CLAUDE_PANE:-window:$CLAUDE_WIN}" >> /tmp/tabby-indicator-debug.log
            fi
        else
            # Clear bell on the specific pane when possible.
            if [ -n "$CLAUDE_PANE" ]; then
                tmux set-option -p -t "$CLAUDE_PANE" -u @tabby_bell 2>/dev/null
                echo "Cleared bell on pane $CLAUDE_PANE" >> /tmp/tabby-indicator-debug.log
            elif [ -n "$CLAUDE_WIN" ]; then
                tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_bell 2>/dev/null
                echo "Cleared bell on window $CLAUDE_WIN (focused)" >> /tmp/tabby-indicator-debug.log
            fi
        fi
        ;;
    activity)
        if [ "$VALUE" = "1" ]; then
            [ -n "$CLAUDE_WIN" ] && tmux set-option -t ":$CLAUDE_WIN" -w @tabby_activity 1 2>/dev/null
        else
            [ -n "$CLAUDE_WIN" ] && tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_activity 2>/dev/null
        fi
        ;;
    silence)
        if [ "$VALUE" = "1" ]; then
            [ -n "$CLAUDE_WIN" ] && tmux set-option -t ":$CLAUDE_WIN" -w @tabby_silence 1 2>/dev/null
        else
            [ -n "$CLAUDE_WIN" ] && tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_silence 2>/dev/null
        fi
        ;;
    input)
        if [ "$VALUE" = "1" ]; then
            # Set input needed indicator
            if [ -n "$CLAUDE_WIN" ]; then
                tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_busy 2>/dev/null
                tmux set-option -t ":$CLAUDE_WIN" -w @tabby_input 1 2>/dev/null
                [ -n "$CLAUDE_PANE" ] && tmux set-option -p -t "$CLAUDE_PANE" -u @tabby_input_ack 2>/dev/null
                [ -n "$SESSION" ] && echo "$CLAUDE_WIN" > "$STATE_DIR/last-${SESSION}"
                echo "Set input on window $CLAUDE_WIN" >> /tmp/tabby-indicator-debug.log
            fi
        else
            # Clear input indicator
            if [ -n "$CLAUDE_WIN" ]; then
                tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_input 2>/dev/null
                echo "Cleared input on window $CLAUDE_WIN" >> /tmp/tabby-indicator-debug.log
            fi
        fi
        ;;
    crash)
        if [ "$VALUE" = "1" ]; then
            if [ -n "$CLAUDE_WIN" ]; then
                tmux set-option -t ":$CLAUDE_WIN" -w @tabby_crash 1 2>/dev/null
            fi
        else
            if [ -n "$CLAUDE_WIN" ]; then
                tmux set-option -t ":$CLAUDE_WIN" -wu @tabby_crash 2>/dev/null
            fi
        fi
        ;;
esac

# Signal the daemon to refresh immediately (USR1 triggers instant re-render).
# Keep this socket-prefix aware so hooks work in shared/named tmux sockets.
SESSION_ID=$(tmux display-message -p '#{session_id}' 2>/dev/null)
SESSION_ID="$(tabby_canonical_session_id "$SESSION_ID")"
RUNTIME_PREFIX="${TABBY_RUNTIME_PREFIX:-}"
DAEMON_PID_FILE="/tmp/${RUNTIME_PREFIX}tabby-daemon-${SESSION_ID}.pid"
if [ -f "$DAEMON_PID_FILE" ]; then
    kill -USR1 "$(cat "$DAEMON_PID_FILE")" 2>/dev/null || true
fi
