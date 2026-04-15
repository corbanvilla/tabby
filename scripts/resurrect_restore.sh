#!/usr/bin/env bash
set -euo pipefail

RESURRECT_DIR="${TABBY_TMUX_RESURRECT_DIR:-$HOME/.tmux/plugins/tmux-resurrect}"
REAL_RESTORE_SCRIPT="$RESURRECT_DIR/scripts/restore.sh"

[ -x "$REAL_RESTORE_SCRIPT" ] || exit 0

if [ -z "${TMUX:-}" ]; then
    socket_path="${TABBY_TMUX_SOCKET:-}"
    if [ -z "$socket_path" ]; then
        socket_path="$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)"
    fi
    if [ -n "$socket_path" ]; then
        export TMUX="${socket_path},0,0"
    fi
fi

"$REAL_RESTORE_SCRIPT" "$@"
