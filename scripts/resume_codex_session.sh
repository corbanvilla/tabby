#!/usr/bin/env bash
set -euo pipefail

CODEX_BIN="${TABBY_CODEX_BIN:-codex}"
args=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-alt-screen)
            args+=("$1")
            shift
            ;;
        *)
            break
            ;;
    esac
done

session_id="${1:-}"
[ -n "$session_id" ] || exit 1

exec "$CODEX_BIN" "${args[@]}" resume "$session_id"
