#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Real agent session resurrect smoke ==="

if [ "${TABBY_RUN_REAL_AGENT_SMOKE:-0}" != "1" ]; then
    echo "Skipping real agent smoke test (set TABBY_RUN_REAL_AGENT_SMOKE=1 to enable)"
    exit 0
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
SAVE_WRAPPER="$PROJECT_ROOT/scripts/resurrect_save.sh"
RESTORE_WRAPPER="$PROJECT_ROOT/scripts/resurrect_restore.sh"
REAL_RESURRECT_DIR="$HOME/.tmux/plugins/tmux-resurrect"

for cmd in tmux script codex claude sqlite3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Skipping real agent smoke test ($cmd is unavailable)"
        exit 0
    fi
done

if ! codex login status >/dev/null 2>&1; then
    echo "Skipping real agent smoke test (Codex is not authenticated)"
    exit 0
fi

if ! claude auth status >/dev/null 2>&1; then
    echo "Skipping real agent smoke test (Claude is not authenticated)"
    exit 0
fi

export TABBY_TMUX_REAL="$(command -v tmux)"
export PATH="$PROJECT_ROOT/bin:$PATH"

TEST_SESSION="tabby-real-agent-resurrect"
TEST_RESURRECT_DIR="$(mktemp -d /tmp/tabby-real-agent-resurrect.XXXXXX)"
CLAUDE_DIR="$(mktemp -d /tmp/tabby-real-agent-claude.XXXXXX)"
ATTACH_LOG="/tmp/tabby-real-agent-attach-$$.log"
ATTACH_TS="/tmp/tabby-real-agent-attach-$$.typescript"
CLIENT_PID=""
SOCKET_PATH="$(mktemp -u /tmp/tabby-real-agent-smoke.XXXXXX.sock)"
export TABBY_TMUX_SOCKET="$SOCKET_PATH"
CODEX_SESSION_ID="$(sqlite3 "$HOME/.codex/state_5.sqlite" "select id from threads where cwd='$PROJECT_ROOT' order by updated_at desc limit 1;" 2>/dev/null | head -n1)"

tmux() {
    command tmux -f /dev/null "$@"
}

cleanup() {
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" >/dev/null 2>&1 || true
    tmux kill-server >/dev/null 2>&1 || true
    rm -rf "$TEST_RESURRECT_DIR" "$CLAUDE_DIR" >/dev/null 2>&1 || true
    rm -f "$ATTACH_LOG" "$ATTACH_TS" "$SOCKET_PATH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for() {
    local tries="$1"
    shift
    local cmd=("$@")
    local i
    for i in $(seq 1 "$tries"); do
        if "${cmd[@]}"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

tmux_has_client() {
    tmux list-clients -F "#{session_name}" 2>/dev/null | grep -qx "$TEST_SESSION"
}

pane_current_command() {
    local target="${1:-}"
    tmux display-message -p -t "$target" "#{pane_current_command}" 2>/dev/null
}

codex_started() {
    local cmd
    cmd="$(pane_current_command "$TEST_SESSION:codex" || true)"
    [ -n "$cmd" ] && [ "$cmd" != "fish" ]
}

claude_started() {
    [ "$(pane_current_command "$TEST_SESSION:claude" || true)" = "claude" ]
}

find_claude_session_file() {
    find "$HOME/.claude/projects/$(printf '%s' "$CLAUDE_DIR" | sed 's/[^A-Za-z0-9]/-/g')" \
        -maxdepth 1 -type f -name '*.jsonl' -print 2>/dev/null \
        | while IFS= read -r file; do
            if grep -q "$SMOKE_NONCE" "$file" 2>/dev/null; then
                printf '%s\n' "$file"
                break
            fi
        done
}

save_file_path() {
    printf '%s/last\n' "$TEST_RESURRECT_DIR"
}

if [ -z "$CODEX_SESSION_ID" ]; then
    echo "Skipping real agent smoke test (no existing Codex session found for $PROJECT_ROOT)"
    exit 0
fi

tmux new-session -d -s "$TEST_SESSION" -n codex -c "$PROJECT_ROOT"
tmux new-window -t "$TEST_SESSION:" -n claude -c "$CLAUDE_DIR"
tmux set-environment -g TABBY_TMUX_RESURRECT_DIR "$REAL_RESURRECT_DIR"
tmux set-option -g @resurrect-dir "$TEST_RESURRECT_DIR"
tmux set-option -g @resurrect-processes '"~resume_codex_session.sh" "~resume_claude_session.sh"'

SMOKE_NONCE="tabby-smoke-$(date +%s)-$$"
CLAUDE_PROMPT="Reply with exactly $SMOKE_NONCE and then wait for my next message."

tmux send-keys -t "$TEST_SESSION:codex" "codex --no-alt-screen resume \"$CODEX_SESSION_ID\"" C-m
tmux send-keys -t "$TEST_SESSION:claude" "claude --dangerously-skip-permissions --tools \"\"" C-m

if ! wait_for 60 codex_started; then
    echo "✗ real Codex CLI did not start"
    tmux capture-pane -pt "$TEST_SESSION:codex" | tail -n 80 || true
    exit 1
fi

if ! wait_for 60 claude_started; then
    echo "✗ real Claude CLI did not start"
    tmux capture-pane -pt "$TEST_SESSION:claude" | tail -n 80 || true
    exit 1
fi

sleep 2
tmux send-keys -t "$TEST_SESSION:claude" -l "$CLAUDE_PROMPT"
tmux send-keys -t "$TEST_SESSION:claude" C-m

if ! wait_for 60 bash -lc 'bash "'"$SAVE_WRAPPER"'" >/dev/null 2>&1 && grep -q "'"$CODEX_SESSION_ID"'" "'"$TEST_RESURRECT_DIR"'/last"'; then
    echo "✗ real Codex resume session did not save back to the expected session id"
    [ -f "$TEST_RESURRECT_DIR/last" ] && cat "$TEST_RESURRECT_DIR/last" || true
    exit 1
fi

CLAUDE_SESSION_FILE=""
if ! wait_for 120 bash -lc 'find "$HOME/.claude/projects/$(printf "%s" "'"$CLAUDE_DIR"'" | sed '"'"'s/[^A-Za-z0-9]/-/g'"'"')" -maxdepth 1 -type f -name "*.jsonl" -print 2>/dev/null | xargs -r grep -l "'"$SMOKE_NONCE"'" >/dev/null 2>&1'; then
    echo "✗ real Claude session did not persist expected nonce"
    exit 1
fi
CLAUDE_SESSION_FILE="$(find_claude_session_file)"
CLAUDE_SESSION_ID="$(basename "$CLAUDE_SESSION_FILE" .jsonl)"

if [ -n "$CLAUDE_SESSION_ID" ]; then
    echo "✓ real Claude session persisted prompt nonce"
    echo "✓ real Codex session resumed from existing local state"
else
    echo "✗ failed to discover persisted session ids"
    exit 1
fi

bash "$SAVE_WRAPPER"
SAVE_FILE="$(save_file_path)"
[ -f "$SAVE_FILE" ] || { echo "✗ resurrect save file missing"; exit 1; }

if grep -q "$CODEX_SESSION_ID" "$SAVE_FILE" && grep -q "$CLAUDE_SESSION_ID" "$SAVE_FILE"; then
    echo "✓ save wrapper captured real agent session ids"
else
    echo "✗ save wrapper did not capture real agent session ids"
    cat "$SAVE_FILE"
    exit 1
fi

tmux kill-server >/dev/null 2>&1 || true

tmux new-session -d -s "$TEST_SESSION" -n shell
tmux set-environment -g TABBY_TMUX_RESURRECT_DIR "$REAL_RESURRECT_DIR"
tmux set-option -g @resurrect-dir "$TEST_RESURRECT_DIR"
tmux set-option -g @resurrect-processes '"~resume_codex_session.sh" "~resume_claude_session.sh"'

TERM=xterm script -q -c "TERM=xterm $TABBY_TMUX_REAL -S '$SOCKET_PATH' -f /dev/null attach-session -t '$TEST_SESSION'" "$ATTACH_TS" >"$ATTACH_LOG" 2>&1 &
CLIENT_PID=$!

if ! wait_for 30 tmux_has_client; then
    echo "✗ failed to attach restore client"
    tail -n 40 "$ATTACH_LOG" 2>/dev/null || true
    exit 1
fi

"$RESTORE_WRAPPER" >/dev/null 2>&1 || true

if ! wait_for 120 bash -lc 'bash "'"$SAVE_WRAPPER"'" >/dev/null 2>&1 && grep -q "'"$CODEX_SESSION_ID"'" "'"$TEST_RESURRECT_DIR"'/last" && grep -q "'"$CLAUDE_SESSION_ID"'" "'"$TEST_RESURRECT_DIR"'/last"'; then
    echo "✗ restored real agent panes did not save back to the same session ids"
    [ -f "$TEST_RESURRECT_DIR/last" ] && cat "$TEST_RESURRECT_DIR/last" || true
    exit 1
fi

if sqlite3 "$HOME/.codex/state_5.sqlite" "select id from threads where id='$CODEX_SESSION_ID' limit 1;" 2>/dev/null | grep -q "$CODEX_SESSION_ID" && \
   grep -q "$SMOKE_NONCE" "$CLAUDE_SESSION_FILE"; then
    echo "✓ restored real agent sessions still point at the original persisted conversation state"
else
    echo "✗ persisted real agent conversation state no longer matches the original nonce"
    exit 1
fi

echo "=== Real agent session resurrect smoke test passed ==="
