#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
SET_IND="$PROJECT_ROOT/scripts/set-tabby-indicator.sh"

LABEL="${1:-mock-ai}"
READY_FILE="${2:-}"
WORK_DELAY="${MOCK_AI_WORK_DELAY:-0.5}"

if [ -z "${TMUX_PANE:-}" ]; then
  echo "TMUX_PANE is required" >&2
  exit 1
fi

TMUX_PANE="$TMUX_PANE" "$SET_IND" busy 1
printf '[%s] busy\n' "$LABEL"
sleep "$WORK_DELAY"
TMUX_PANE="$TMUX_PANE" "$SET_IND" busy 0
TMUX_PANE="$TMUX_PANE" "$SET_IND" bell 1
printf '[%s] ready\n' "$LABEL"

if [ -n "$READY_FILE" ]; then
  : >"$READY_FILE"
fi
