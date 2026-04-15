#!/usr/bin/env bash
# Rename a pane and lock the title
# Usage: rename_pane.sh <pane_id> <new_title>

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PANE_ID="$1"
NEW_TITLE="$2"

if [ -z "$PANE_ID" ] || [ -z "$NEW_TITLE" ]; then
    exit 1
fi

# Set the pane title
tmux select-pane -t "$PANE_ID" -T "$NEW_TITLE"

# Lock it with our custom option
tmux set-option -p -t "$PANE_ID" @tabby_pane_title "$NEW_TITLE"

"$CURRENT_DIR/signal_sidebar.sh" >/dev/null 2>&1 || true
tmux refresh-client -S 2>/dev/null || true
