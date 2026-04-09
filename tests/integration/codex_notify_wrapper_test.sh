#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Codex notify wrapper chains Tabby + existing hook ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
WRAPPER="$PROJECT_ROOT/scripts/codex-notify-tabby-wrapper.sh"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

LOG_FILE="$TMP_DIR/log.txt"

cat >"$TMP_DIR/set-tabby-indicator.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'indicator:%s:%s\n' "$1" "$2" >>"$TABBY_TEST_LOG"
SH
chmod +x "$TMP_DIR/set-tabby-indicator.sh"

cat >"$TMP_DIR/original-hook.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'hook:%s\n' "$*" >>"$TABBY_TEST_LOG"
SH
chmod +x "$TMP_DIR/original-hook.sh"

WRAPPER_COPY="$TMP_DIR/codex-notify-tabby-wrapper.sh"
cp "$WRAPPER" "$WRAPPER_COPY"
chmod +x "$WRAPPER_COPY"

TABBY_TEST_LOG="$LOG_FILE" bash "$WRAPPER_COPY" "$TMP_DIR/original-hook.sh" alpha beta

grep -q '^indicator:busy:0$' "$LOG_FILE" || { echo "missing busy clear"; cat "$LOG_FILE"; exit 1; }
grep -q '^indicator:input:0$' "$LOG_FILE" || { echo "missing input clear"; cat "$LOG_FILE"; exit 1; }
grep -q '^indicator:bell:1$' "$LOG_FILE" || { echo "missing bell set"; cat "$LOG_FILE"; exit 1; }
grep -q '^hook:alpha beta$' "$LOG_FILE" || { echo "missing chained hook"; cat "$LOG_FILE"; exit 1; }

echo "=== Codex notify wrapper test passed ==="
