#!/usr/bin/env bash
# resurrect_integration_test.sh
#
# Integration tests for Tabby + tmux-resurrect hook scripts.
# Tests save-file filtering and restore-hook behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABBY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SAVE_WRAPPER="$TABBY_ROOT/scripts/resurrect_save.sh"
SAVE_HOOK="$TABBY_ROOT/scripts/resurrect_save_hook.sh"
RESTORE_HOOK="$TABBY_ROOT/scripts/resurrect_restore_hook.sh"
AUTOSAVE_HOOK="$TABBY_ROOT/scripts/resurrect_autosave.sh"
RESTORE_WRAPPER="$TABBY_ROOT/scripts/resurrect_restore.sh"
FAILED=0
TEST_SESSION="tabby-resurrect-hooks"

export TABBY_TMUX_REAL="${TABBY_TMUX_REAL:-$(command -v tmux)}"
source "$TABBY_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-resurrect-hooks"

cleanup() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    tabby_cleanup_tmux_test_env
}
trap cleanup EXIT

pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; ((FAILED++)); }

echo "=== Integration Test: Resurrect Hooks ==="

tmux new-session -d -s "$TEST_SESSION" -n "main"
bash "$TABBY_ROOT/tabby.tmux"
sleep 0.2

# --- Test 1: Save hook strips Tabby pane lines ---

TMPFILE=$(mktemp)
printf 'window\tmain\t0\tcode\t1\t*\t{layout}\n' > "$TMPFILE"
printf 'pane\tmain\t0\tcode\t1\t*\t0\t/home\t1\tbash\tbash\n' >> "$TMPFILE"
printf 'pane\tmain\t0\tcode\t1\t*\t1\t/home\t0\tsidebar-renderer\tsidebar-renderer --session main\n' >> "$TMPFILE"
printf 'pane\tmain\t0\tcode\t1\t*\t2\t/home\t0\tpane-header\tpane-header --pane 0\n' >> "$TMPFILE"
printf 'pane\tmain\t1\tnotes\t0\t-\t0\t/home\t1\tvim\tvim notes.md\n' >> "$TMPFILE"
printf 'state\tsome_state_data\n' >> "$TMPFILE"

bash "$SAVE_HOOK" "$TMPFILE"

REMAINING_PANES=$(grep '^pane' "$TMPFILE" | wc -l | tr -d ' ')
if [ "$REMAINING_PANES" -eq 2 ]; then
    pass "Save hook kept 2 user panes (bash, vim)"
else
    fail "Save hook kept $REMAINING_PANES panes, expected 2"
fi

if grep -q 'sidebar-renderer\|pane-header' "$TMPFILE"; then
    fail "Save hook left Tabby pane lines in file"
else
    pass "Save hook stripped all Tabby pane lines"
fi

if grep -q '^window' "$TMPFILE" && grep -q '^state' "$TMPFILE"; then
    pass "Save hook preserved window and state lines"
else
    fail "Save hook damaged non-pane lines"
fi

rm -f "$TMPFILE"

# --- Test 1b: Save hook strips truncated process names (macOS MAXCOMLEN=15) ---

TMPFILE=$(mktemp)
printf 'pane\tmain\t0\tcode\t1\t*\t0\t/home\t1\tbash\tbash\n' > "$TMPFILE"
printf 'pane\tmain\t0\tcode\t1\t*\t1\t/home\t0\tsidebar-rendere\tsidebar-rendere\n' >> "$TMPFILE"
printf 'pane\tmain\t0\tcode\t1\t*\t2\t/home\t1\tvim\tvim\n' >> "$TMPFILE"

bash "$SAVE_HOOK" "$TMPFILE"

REMAINING_PANES=$(grep '^pane' "$TMPFILE" | wc -l | tr -d ' ')
if [ "$REMAINING_PANES" -eq 2 ]; then
    pass "Save hook strips truncated 'sidebar-rendere' (MAXCOMLEN)"
else
    fail "Save hook kept $REMAINING_PANES panes with truncated name, expected 2"
fi
rm -f "$TMPFILE"

# --- Test 2: Save hook handles missing/empty file gracefully ---

bash "$SAVE_HOOK" "" 2>/dev/null && pass "Save hook handles empty path" || fail "Save hook crashed on empty path"
bash "$SAVE_HOOK" "/nonexistent/file" 2>/dev/null && pass "Save hook handles missing file" || fail "Save hook crashed on missing file"

# --- Test 3: Save hook is idempotent (no Tabby panes = no change) ---

TMPFILE=$(mktemp)
printf 'pane\tmain\t0\tcode\t1\t*\t0\t/home\t1\tbash\tbash\n' > "$TMPFILE"
printf 'pane\tmain\t1\tnotes\t0\t-\t0\t/home\t1\tvim\tvim\n' >> "$TMPFILE"
BEFORE=$(cat "$TMPFILE")
bash "$SAVE_HOOK" "$TMPFILE"
AFTER=$(cat "$TMPFILE")

if [ "$BEFORE" = "$AFTER" ]; then
    pass "Save hook is idempotent on clean files"
else
    fail "Save hook modified a file with no Tabby panes"
fi
rm -f "$TMPFILE"

# --- Test 4: Restore hook script is valid and executable ---

if [ -x "$RESTORE_HOOK" ]; then
    pass "Restore hook is executable"
else
    fail "Restore hook is not executable"
fi

bash -n "$RESTORE_HOOK" 2>/dev/null && pass "Restore hook passes syntax check" || fail "Restore hook has syntax errors"

if [ -x "$AUTOSAVE_HOOK" ]; then
    pass "Autosave helper is executable"
else
    fail "Autosave helper is not executable"
fi

bash -n "$AUTOSAVE_HOOK" 2>/dev/null && pass "Autosave helper passes syntax check" || fail "Autosave helper has syntax errors"

if [ -x "$RESTORE_WRAPPER" ]; then
    pass "Restore wrapper is executable"
else
    fail "Restore wrapper is not executable"
fi

bash -n "$RESTORE_WRAPPER" 2>/dev/null && pass "Restore wrapper passes syntax check" || fail "Restore wrapper has syntax errors"

# --- Test 5: Hook options are wired in tmux ---

SAVE_OPT=$(tmux show-option -gqv @resurrect-hook-post-save-layout 2>/dev/null || echo "")
RESTORE_OPT=$(tmux show-option -gqv @resurrect-hook-post-restore-all 2>/dev/null || echo "")
SAVE_PATH_OPT=$(tmux show-option -gqv @resurrect-save-script-path 2>/dev/null || echo "")
RESTORE_PATH_OPT=$(tmux show-option -gqv @resurrect-restore-script-path 2>/dev/null || echo "")
PROC_OPT=$(tmux show-option -gqv @resurrect-processes 2>/dev/null || echo "")

if echo "$SAVE_OPT" | grep -q "resurrect_save_hook"; then
    pass "Save hook wired in tmux options"
else
    fail "Save hook not found in @resurrect-hook-post-save-layout (got: '$SAVE_OPT')"
fi

if echo "$RESTORE_OPT" | grep -q "resurrect_restore_hook"; then
    pass "Restore hook wired in tmux options"
else
    fail "Restore hook not found in @resurrect-hook-post-restore-all (got: '$RESTORE_OPT')"
fi

if echo "$SAVE_PATH_OPT" | grep -q "resurrect_save.sh"; then
    pass "Save wrapper wired in tmux options"
else
    fail "Save wrapper not found in @resurrect-save-script-path (got: '$SAVE_PATH_OPT')"
fi

if echo "$RESTORE_PATH_OPT" | grep -q "resurrect_restore.sh"; then
    pass "Restore wrapper wired in tmux options"
else
    fail "Restore wrapper not found in @resurrect-restore-script-path (got: '$RESTORE_PATH_OPT')"
fi

if echo "$PROC_OPT" | grep -q "resume_codex_session.sh" && echo "$PROC_OPT" | grep -q "resume_claude_session.sh"; then
    pass "Resurrect process list includes agent resume helpers"
else
    fail "Resurrect process list missing agent resume helpers (got: '$PROC_OPT')"
fi

# --- Test 6: Save wrapper repairs broken last symlink from same-second collisions ---

FAKE_RESURRECT_DIR="$(mktemp -d)"
SAVE_OUTPUT_DIR="$(mktemp -d)"
COUNTER_FILE="$FAKE_RESURRECT_DIR/save-count"
mkdir -p "$FAKE_RESURRECT_DIR/scripts" "$FAKE_RESURRECT_DIR/save_command_strategies"

cat > "$FAKE_RESURRECT_DIR/scripts/save.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/save-count"
save_dir="$(tmux show-option -gqv @resurrect-dir)"
mkdir -p "$save_dir"

count=0
if [ -f "$count_file" ]; then
    count="$(cat "$count_file")"
fi
count="$((count + 1))"
printf '%s\n' "$count" > "$count_file"

case "$count" in
    1)
        file="$save_dir/tmux_resurrect_20260101T000000.txt"
        printf 'first\n' > "$file"
        ln -sfn "$(basename "$file")" "$save_dir/last"
        ;;
    2)
        rm -f "$save_dir/tmux_resurrect_20260101T000000.txt"
        ln -sfn "tmux_resurrect_20260101T000000.txt" "$save_dir/last"
        ;;
    *)
        file="$save_dir/tmux_resurrect_20260101T000001.txt"
        printf 'repaired\n' > "$file"
        ln -sfn "$(basename "$file")" "$save_dir/last"
        ;;
esac
EOF
chmod +x "$FAKE_RESURRECT_DIR/scripts/save.sh"

tmux set-option -g @resurrect-dir "$SAVE_OUTPUT_DIR"
TABBY_TMUX_RESURRECT_DIR="$FAKE_RESURRECT_DIR" bash "$SAVE_WRAPPER"
TABBY_TMUX_RESURRECT_DIR="$FAKE_RESURRECT_DIR" bash "$SAVE_WRAPPER"

if [ -e "$SAVE_OUTPUT_DIR/last" ] && [ "$(cat "$SAVE_OUTPUT_DIR/last")" = "repaired" ] && [ "$(cat "$COUNTER_FILE")" = "3" ]; then
    pass "Save wrapper repairs broken 'last' symlinks caused by same-second collisions"
else
    fail "Save wrapper did not repair broken 'last' symlink collision state"
fi

rm -rf "$FAKE_RESURRECT_DIR" "$SAVE_OUTPUT_DIR"

# --- Results ---

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "=== All resurrect integration tests passed ==="
else
    echo "=== $FAILED resurrect test(s) FAILED ==="
    exit 1
fi
