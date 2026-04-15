#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Resurrect autosave debounce ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
AUTOSAVE_SCRIPT="$PROJECT_ROOT/scripts/resurrect_autosave.sh"

tmux_real="${TABBY_TMUX_REAL:-$(command -v tmux)}"
if [ -z "$tmux_real" ]; then
    echo "tmux is required for this test"
    exit 1
fi
export TABBY_TMUX_REAL="$tmux_real"

source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"

TABBY_TEST_HOME="$(mktemp -d /tmp/tabby-resurrect-home.XXXXXX)"
TABBY_TEST_RUNTIME="$(mktemp -d /tmp/tabby-resurrect-runtime.XXXXXX)"
export HOME="$TABBY_TEST_HOME"
export XDG_RUNTIME_DIR="$TABBY_TEST_RUNTIME"
export TABBY_TEST_SAVE_LOG="$TABBY_TEST_RUNTIME/save.log"
export TABBY_TEST_HOOK_LOG="$TABBY_TEST_RUNTIME/hook.log"
export TABBY_TEST_SAVE_SLEEP="0.20"

tabby_init_tmux_test_env "tabby-tests-resurrect-autosave"
TEST_SESSION="tabby-resurrect-autosave"

cleanup() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    tabby_cleanup_tmux_test_env
    rm -rf "$TABBY_TEST_HOME" "$TABBY_TEST_RUNTIME"
}
trap cleanup EXIT

mkdir -p "$HOME/.tmux/plugins/tmux-resurrect/scripts"
cat > "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep "${TABBY_TEST_SAVE_SLEEP:-0}"
printf '%s\n' "$(date +%s%N)" >> "${TABBY_TEST_SAVE_LOG:?}"
EOF
chmod +x "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"

PRE_HOOK_SCRIPT="$TABBY_TEST_RUNTIME/pre-existing-hook.sh"
cat > "$PRE_HOOK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'pre\n' >> "$TABBY_TEST_HOOK_LOG"
EOF
chmod +x "$PRE_HOOK_SCRIPT"

wait_for_count() {
    local expected="$1"
    local path="$2"
    local tries="${3:-50}"
    local i count
    for i in $(seq 1 "$tries"); do
        if [ -f "$path" ]; then
            count="$(wc -l < "$path" | tr -d ' ')"
        else
            count=0
        fi
        if [ "$count" = "$expected" ]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

count_lines() {
    local path="$1"
    if [ -f "$path" ]; then
        wc -l < "$path" | tr -d ' '
    else
        echo 0
    fi
}

tmux new-session -d -s "$TEST_SESSION" -n "main"
tmux set-option -g @resurrect_autosave_debounce_seconds 1

PRE_HOOK_CMD="run-shell -b '$PRE_HOOK_SCRIPT'"
AUTOSAVE_HOOK_CMD="run-shell -b '$AUTOSAVE_SCRIPT'"

tmux set-hook -g after-new-window "$PRE_HOOK_CMD"
for hook in after-new-window window-unlinked after-split-window after-kill-pane pane-exited client-detached; do
    tmux set-hook -ag "$hook" "$AUTOSAVE_HOOK_CMD"
done

hook_dump="$(tmux show-hooks -g after-new-window)"
if echo "$hook_dump" | grep -q "$AUTOSAVE_SCRIPT" && echo "$hook_dump" | grep -q "$PRE_HOOK_SCRIPT"; then
    echo "✓ autosave hook appends alongside existing after-new-window hooks"
else
    echo "✗ after-new-window hook chain missing expected entries"
    echo "$hook_dump"
    exit 1
fi

start_ns="$(date +%s%N)"
tmux new-window -t "$TEST_SESSION:" -n "burst-a"
tmux split-window -d -t "$TEST_SESSION:0"
burst_pane="$(tmux list-panes -t "$TEST_SESSION:0" -F "#{pane_id}" | tail -n 1)"
tmux kill-pane -t "$burst_pane"
tmux kill-window -t "$TEST_SESSION:1"
end_ns="$(date +%s%N)"
burst_ms="$(( (end_ns - start_ns) / 1000000 ))"

if ! wait_for_count 1 "$TABBY_TEST_SAVE_LOG" 60; then
    echo "✗ burst of structural hooks did not debounce to a single save"
    echo "save log count: $(count_lines "$TABBY_TEST_SAVE_LOG")"
    exit 1
fi
echo "✓ burst of structural hooks debounced to one save"

if ! wait_for_count 1 "$TABBY_TEST_HOOK_LOG" 30; then
    echo "✗ pre-existing after-new-window hook did not run"
    exit 1
fi
echo "✓ pre-existing after-new-window hook still ran"

if [ "$burst_ms" -lt 2000 ]; then
    echo "✓ burst operations completed in ${burst_ms}ms with background autosave"
else
    echo "✗ burst operations took too long with autosave enabled (${burst_ms}ms)"
    exit 1
fi

sleep 1.2
tmux new-window -t "$TEST_SESSION:" -n "after-debounce"

if ! wait_for_count 2 "$TABBY_TEST_SAVE_LOG" 60; then
    echo "✗ second save did not occur after debounce interval"
    echo "save log count: $(count_lines "$TABBY_TEST_SAVE_LOG")"
    exit 1
fi
echo "✓ save runs again after debounce interval expires"

rm -f "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" "$TABBY_TEST_RUNTIME/missing.log"
TABBY_TEST_SAVE_LOG="$TABBY_TEST_RUNTIME/missing.log" bash "$AUTOSAVE_SCRIPT"
if [ -e "$TABBY_TEST_RUNTIME/missing.log" ]; then
    echo "✗ autosave helper wrote output even though tmux-resurrect was absent"
    exit 1
fi
echo "✓ autosave helper is a no-op when tmux-resurrect is not installed"

echo "=== Resurrect autosave debounce test passed ==="
