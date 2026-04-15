#!/usr/bin/env bash
#
# resurrect_autosave.sh — debounced tmux-resurrect autosave helper
#
# Intended to be run from tmux hooks such as after-new-window, after-split-window,
# pane-exited, and client-detached. It is a no-op unless tmux-resurrect is
# installed in ~/.tmux/plugins/tmux-resurrect.

set -euo pipefail

AUTOSAVE_ENABLED="$(tmux show-option -gqv @tabby_resurrect_autosave 2>/dev/null || true)"
case "${AUTOSAVE_ENABLED:-on}" in
    0|off|false|no)
        exit 0
        ;;
esac

SAVE_SCRIPT="$(tmux show-option -gqv @resurrect-save-script-path 2>/dev/null || true)"
[ -n "$SAVE_SCRIPT" ] || SAVE_SCRIPT="$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"
[ -x "$SAVE_SCRIPT" ] || exit 0

DEBOUNCE_SECONDS="$(tmux show-option -gqv @resurrect_autosave_debounce_seconds 2>/dev/null || true)"
case "${DEBOUNCE_SECONDS:-}" in
    ''|*[!0-9]*)
        DEBOUNCE_SECONDS=30
        ;;
esac

RUNTIME_ROOT="${XDG_RUNTIME_DIR:-/tmp}"
STATE_DIR="$RUNTIME_ROOT/tmux-resurrect-autosave"
STAMP_FILE="$STATE_DIR/last-save"
LOCK_DIR="$STATE_DIR/lock"

mkdir -p "$STATE_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit 0
fi

cleanup() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

now="$(date +%s)"
last=0
if [ -f "$STAMP_FILE" ]; then
    read -r last < "$STAMP_FILE" || last=0
fi
case "${last:-}" in
    ''|*[!0-9]*)
        last=0
        ;;
esac

if [ $((now - last)) -lt "$DEBOUNCE_SECONDS" ]; then
    exit 0
fi

printf '%s\n' "$now" > "$STAMP_FILE"
"$SAVE_SCRIPT" >/dev/null 2>&1 || true
