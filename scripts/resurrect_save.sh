#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESURRECT_DIR="${TABBY_TMUX_RESURRECT_DIR:-$HOME/.tmux/plugins/tmux-resurrect}"
REAL_SAVE_SCRIPT="$RESURRECT_DIR/scripts/save.sh"
STRATEGY_NAME="tabby_agent_sessions"
STRATEGY_PATH="$RESURRECT_DIR/save_command_strategies/${STRATEGY_NAME}.sh"

[ -x "$REAL_SAVE_SCRIPT" ] || exit 0
mkdir -p "$(dirname "$STRATEGY_PATH")"
ln -sf "$SCRIPT_DIR/resurrect_save_command_strategy.sh" "$STRATEGY_PATH"

default_resurrect_dir() {
    if [ -d "$HOME/.tmux/resurrect" ]; then
        printf '%s\n' "$HOME/.tmux/resurrect"
    else
        printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
    fi
}

expand_resurrect_dir() {
    local raw="$1"
    raw="${raw//\$HOME/$HOME}"
    raw="${raw//\$HOSTNAME/$(hostname)}"
    case "$raw" in
        "~"*) raw="$HOME${raw:1}" ;;
    esac
    printf '%s\n' "$raw"
}

configured_resurrect_dir() {
    local raw
    raw="$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)"
    if [ -z "$raw" ]; then
        default_resurrect_dir
    else
        expand_resurrect_dir "$raw"
    fi
}

has_valid_save_artifacts() {
    local dir="$1"
    [ -e "$dir/last" ] && return 0
    compgen -G "$dir/tmux_resurrect_*.txt" >/dev/null 2>&1
}

has_broken_last_symlink() {
    local dir="$1"
    [ -L "$dir/last" ] && [ ! -e "$dir/last" ]
}

previous_strategy="$(tmux show-option -gqv @resurrect-save-command-strategy 2>/dev/null || true)"
tmux set-option -g @resurrect-save-command-strategy "$STRATEGY_NAME"

cleanup() {
    if [ -n "$previous_strategy" ]; then
        tmux set-option -g @resurrect-save-command-strategy "$previous_strategy" 2>/dev/null || true
    else
        tmux set-option -gu @resurrect-save-command-strategy 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

"$REAL_SAVE_SCRIPT" "$@"

resurrect_dir="$(configured_resurrect_dir)"
if has_broken_last_symlink "$resurrect_dir" || ! has_valid_save_artifacts "$resurrect_dir"; then
    sleep 1
    "$REAL_SAVE_SCRIPT" "$@"
fi
