#!/usr/bin/env bash
set -u

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CURRENT_DIR/scripts/_tmux_socket_env.sh"
tabby_init_tmux_socket_env "$CURRENT_DIR"
WINDOW_TARGET="${1:-}"
NEW_NAME="${2:-}"

[ -n "$WINDOW_TARGET" ] || exit 0

tmux rename-window -t "$WINDOW_TARGET" -- "$NEW_NAME" 2>/dev/null || true
tmux set-window-option -t "$WINDOW_TARGET" @tabby_name_locked 1 2>/dev/null || true
"$CURRENT_DIR/scripts/signal_sidebar.sh" "$WINDOW_TARGET" >/dev/null 2>&1 || true
"$CURRENT_DIR/scripts/refresh_status.sh" >/dev/null 2>&1 || true
