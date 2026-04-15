#!/usr/bin/env bash
set -euo pipefail

CLAUDE_BIN="${TABBY_CLAUDE_BIN:-claude}"
session_id="${1:-}"
[ -n "$session_id" ] || exit 1

exec "$CLAUDE_BIN" --resume "$session_id"
