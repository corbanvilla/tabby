#!/usr/bin/env bash
set -eu

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

SESSION_ID="${1:-}"
WINDOW_ID="${2:-}"

sleep 0.2
for _ in 1 2 3 4 5; do
    "$CURRENT_DIR/scripts/cleanup_orphan_sidebar.sh" "$SESSION_ID" "$WINDOW_ID" >/dev/null 2>&1 || true
    sleep 0.2
done
