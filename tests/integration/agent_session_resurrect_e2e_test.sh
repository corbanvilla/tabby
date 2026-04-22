#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Agent session resurrect end-to-end ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
SAVE_WRAPPER="$PROJECT_ROOT/scripts/resurrect_save.sh"
RESTORE_WRAPPER="$PROJECT_ROOT/scripts/resurrect_restore.sh"
REAL_RESURRECT_DIR="$HOME/.tmux/plugins/tmux-resurrect"

export TABBY_TMUX_REAL="${TABBY_TMUX_REAL:-$(command -v tmux)}"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-agent-resurrect-e2e"

TEST_SESSION="tabby-agent-resurrect-e2e"
TEST_HOME="$(mktemp -d /tmp/tabby-agent-e2e-home.XXXXXX)"
TEST_BIN="$(mktemp -d /tmp/tabby-agent-e2e-bin.XXXXXX)"
CODEX_DIR="$(mktemp -d /tmp/tabby-agent-e2e-codex.XXXXXX)"
CLAUDE_DIR="$(mktemp -d /tmp/tabby-agent-e2e-claude.XXXXXX)"
STATE_DB="$TEST_HOME/codex-state.sqlite"
CLAUDE_PROJECTS="$TEST_HOME/claude-projects"
LOG_DIR="$TEST_HOME/logs"
XDG_DATA_HOME="$TEST_HOME/.local/share"
mkdir -p "$CLAUDE_PROJECTS" "$LOG_DIR"

cleanup() {
    if [ -n "${ATTACH_PID:-}" ]; then
        kill "$ATTACH_PID" 2>/dev/null || true
    fi
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    tabby_cleanup_tmux_test_env
    rm -rf "$TEST_HOME" "$TEST_BIN" "$CODEX_DIR" "$CLAUDE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

cat > "$TEST_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex:%s\n' "$*" >> "${TABBY_AGENT_RESTORE_LOG:?}"
args=("$@")
resume_index=0
if [ "${args[$resume_index]:-}" = "resume" ]; then
    session_id="${args[$((resume_index + 1))]:-}"
    nonce="$(sqlite3 "${TABBY_CODEX_STATE_DB:?}" "select title from threads where id='$session_id' limit 1;" 2>/dev/null | tr -d '\r')"
    printf 'codex-session:%s:%s\n' "$session_id" "$nonce" >> "${TABBY_AGENT_RESTORE_LOG:?}"
fi
sleep 5
EOF
chmod +x "$TEST_BIN/codex"

cat > "$TEST_BIN/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'claude:%s\n' "$*" >> "${TABBY_AGENT_RESTORE_LOG:?}"
if [ "${1:-}" = "--resume" ]; then
    session_id="${2:-}"
    session_file="$(find "${TABBY_CLAUDE_PROJECTS_DIR:?}" -type f -name "$session_id.jsonl" 2>/dev/null | head -n1 || true)"
    nonce=""
    if [ -n "$session_file" ] && [ -f "$session_file" ]; then
        nonce="$(tr -d '\n' < "$session_file" | sed 's/.*"customTitle":"\([^"]*\)".*/\1/' || true)"
    fi
    printf 'claude-session:%s:%s\n' "$session_id" "$nonce" >> "${TABBY_AGENT_RESTORE_LOG:?}"
fi
sleep 5
EOF
chmod +x "$TEST_BIN/claude"

cat > "$TEST_BIN/codex.js" <<'EOF'
setInterval(() => {}, 1000);
EOF

sqlite3 "$STATE_DB" 'create table threads(id text, cwd text, updated_at integer, title text);'
codex_session_id="codex-e2e-session"
claude_session_id="claude-e2e-session"
probe_nonce="ping-$(date +%s)-$$"
now="$(date +%s)"
sqlite3 "$STATE_DB" "insert into threads(id, cwd, updated_at, title) values('$codex_session_id', '$CODEX_DIR', $now, '$probe_nonce');"

claude_project_dir="$CLAUDE_PROJECTS/$(printf '%s' "$CLAUDE_DIR" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$claude_project_dir"
printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$probe_nonce" "$claude_session_id" > "$claude_project_dir/$claude_session_id.jsonl"

export PATH="$TEST_BIN:$PATH"
export HOME="$TEST_HOME"
export XDG_DATA_HOME
export TABBY_TMUX_RESURRECT_DIR="$REAL_RESURRECT_DIR"
export TABBY_CODEX_STATE_DB="$STATE_DB"
export TABBY_CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS"
export TABBY_CODEX_BIN="$TEST_BIN/codex"
export TABBY_CLAUDE_BIN="$TEST_BIN/claude"
export TABBY_AGENT_RESTORE_LOG="$LOG_DIR/restore.log"

tmux new-session -d -s "$TEST_SESSION" -n codex -c "$CODEX_DIR"
tmux new-window -t "$TEST_SESSION:" -n claude -c "$CLAUDE_DIR"

tmux set-environment -g HOME "$TEST_HOME"
tmux set-environment -g XDG_DATA_HOME "$XDG_DATA_HOME"
tmux set-environment -g PATH "$TEST_BIN:$PATH"
tmux set-environment -g TABBY_TMUX_RESURRECT_DIR "$REAL_RESURRECT_DIR"
tmux set-environment -g TABBY_CODEX_STATE_DB "$STATE_DB"
tmux set-environment -g TABBY_CLAUDE_PROJECTS_DIR "$CLAUDE_PROJECTS"
tmux set-environment -g TABBY_CODEX_BIN "$TEST_BIN/codex"
tmux set-environment -g TABBY_CLAUDE_BIN "$TEST_BIN/claude"
tmux set-environment -g TABBY_AGENT_RESTORE_LOG "$TABBY_AGENT_RESTORE_LOG"
tmux set-option -g @resurrect-processes '"~resume_codex_session.sh" "~resume_claude_session.sh"'

tmux send-keys -t "$TEST_SESSION:codex" "node $TEST_BIN/codex.js restore-probe" C-m
tmux send-keys -t "$TEST_SESSION:claude" "$TEST_BIN/claude restore-probe" C-m
sleep 1

bash "$SAVE_WRAPPER"
SAVE_FILE="$TEST_HOME/.tmux/resurrect/last"
[ -f "$SAVE_FILE" ] || SAVE_FILE="$XDG_DATA_HOME/tmux/resurrect/last"

if [ ! -f "$SAVE_FILE" ]; then
    echo "✗ resurrect save file was not created"
    exit 1
fi

if grep -q 'resume_codex_session.sh' "$SAVE_FILE" && grep -q "$codex_session_id" "$SAVE_FILE"; then
    echo "✓ save file captured codex resume command"
else
    echo "✗ save file missing codex resume command"
    cat "$SAVE_FILE"
    exit 1
fi

if grep -q 'resume_claude_session.sh' "$SAVE_FILE" && grep -q "$claude_session_id" "$SAVE_FILE"; then
    echo "✓ save file captured claude resume command"
else
    echo "✗ save file missing claude resume command"
    cat "$SAVE_FILE"
    exit 1
fi

tmux kill-server >/dev/null 2>&1 || true

tmux new-session -d -s fresh -n shell
tmux set-environment -g HOME "$TEST_HOME"
tmux set-environment -g PATH "$TEST_BIN:$PATH"
tmux set-environment -g TABBY_TMUX_RESURRECT_DIR "$REAL_RESURRECT_DIR"
tmux set-environment -g TABBY_CODEX_BIN "$TEST_BIN/codex"
tmux set-environment -g TABBY_CLAUDE_BIN "$TEST_BIN/claude"
tmux set-environment -g TABBY_AGENT_RESTORE_LOG "$TABBY_AGENT_RESTORE_LOG"
tmux set-option -g @resurrect-processes '"~resume_codex_session.sh" "~resume_claude_session.sh"'

script -qfec "tmux -S \"$TABBY_TEST_SOCKET_PATH\" -f /dev/null attach-session -t fresh" /dev/null >/dev/null 2>&1 &
ATTACH_PID=$!
sleep 1

"$RESTORE_WRAPPER" >/dev/null 2>&1 || true

for _ in $(seq 1 50); do
    [ -f "$TABBY_AGENT_RESTORE_LOG" ] && grep -q "$codex_session_id" "$TABBY_AGENT_RESTORE_LOG" && grep -q "$claude_session_id" "$TABBY_AGENT_RESTORE_LOG" && break
    sleep 0.2
done

if grep -Eq "codex:.*resume $codex_session_id" "$TABBY_AGENT_RESTORE_LOG"; then
    echo "✓ restored codex pane resumed the exact saved session id"
else
    echo "✗ codex resume helper was not invoked with the saved session id"
    cat "$TABBY_AGENT_RESTORE_LOG" 2>/dev/null || true
    exit 1
fi

if grep -q "claude:--resume $claude_session_id" "$TABBY_AGENT_RESTORE_LOG"; then
    echo "✓ restored claude pane resumed the exact saved session id"
else
    echo "✗ claude resume helper was not invoked with the saved session id"
    cat "$TABBY_AGENT_RESTORE_LOG" 2>/dev/null || true
    exit 1
fi

if grep -q "codex-session:$codex_session_id:$probe_nonce" "$TABBY_AGENT_RESTORE_LOG"; then
    echo "✓ restored codex pane recovered the saved session nonce"
else
    echo "✗ restored codex pane did not recover the saved session nonce"
    cat "$TABBY_AGENT_RESTORE_LOG" 2>/dev/null || true
    exit 1
fi

if grep -q "claude-session:$claude_session_id:$probe_nonce" "$TABBY_AGENT_RESTORE_LOG"; then
    echo "✓ restored claude pane recovered the saved session nonce"
else
    echo "✗ restored claude pane did not recover the saved session nonce"
    cat "$TABBY_AGENT_RESTORE_LOG" 2>/dev/null || true
    exit 1
fi

echo "=== Agent session resurrect end-to-end test passed ==="
