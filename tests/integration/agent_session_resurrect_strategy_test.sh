#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Agent session resurrect strategy ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
STRATEGY_SCRIPT="$PROJECT_ROOT/scripts/resurrect_save_command_strategy.sh"

export TABBY_TMUX_REAL="${TABBY_TMUX_REAL:-$(command -v tmux)}"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-agent-resurrect-strategy"

TEST_SESSION="tabby-agent-resurrect-strategy"
TEST_HOME="$(mktemp -d /tmp/tabby-agent-resurrect-home.XXXXXX)"
TEST_BIN="$(mktemp -d /tmp/tabby-agent-resurrect-bin.XXXXXX)"
CODEX_DIR="$(mktemp -d /tmp/tabby-agent-codex.XXXXXX)"
CLAUDE_DIR="$(mktemp -d /tmp/tabby-agent-claude.XXXXXX)"
STATE_DB="$TEST_HOME/codex-state.sqlite"
CLAUDE_PROJECTS="$TEST_HOME/claude-projects"

cleanup() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    tabby_cleanup_tmux_test_env
    rm -rf "$TEST_HOME" "$TEST_BIN" "$CODEX_DIR" "$CLAUDE_DIR"
}
trap cleanup EXIT

mkdir -p "$CLAUDE_PROJECTS"

cat > "$TEST_BIN/claude" <<'EOF'
#!/usr/bin/env bash
sleep 120
EOF
chmod +x "$TEST_BIN/claude"

cat > "$TEST_BIN/codex.js" <<'EOF'
setInterval(() => {}, 1000);
EOF

sqlite3 "$STATE_DB" 'create table threads(id text, cwd text, updated_at integer, title text);'

codex_session_id="codex-session-123"
claude_session_id="claude-session-456"
now="$(date +%s)"
sqlite3 "$STATE_DB" "insert into threads(id, cwd, updated_at, title) values('$codex_session_id', '$CODEX_DIR', $now, 'probe');"

claude_project_dir="$CLAUDE_PROJECTS/$(printf '%s' "$CLAUDE_DIR" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$claude_project_dir"
printf '{"type":"custom-title","sessionId":"%s"}\n' "$claude_session_id" > "$claude_project_dir/$claude_session_id.jsonl"

export PATH="$TEST_BIN:$PATH"
export TABBY_CODEX_STATE_DB="$STATE_DB"
export TABBY_CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS"

tmux new-session -d -s "$TEST_SESSION" -n codex -c "$CODEX_DIR"
tmux new-window -t "$TEST_SESSION:" -n claude -c "$CLAUDE_DIR"
tmux send-keys -t "$TEST_SESSION:codex" "node $TEST_BIN/codex.js strategy-probe" C-m
tmux send-keys -t "$TEST_SESSION:claude" "$TEST_BIN/claude strategy-probe" C-m
sleep 1

codex_pane_pid="$(tmux list-panes -t "$TEST_SESSION:codex" -F "#{pane_pid}")"
claude_pane_pid="$(tmux list-panes -t "$TEST_SESSION:claude" -F "#{pane_pid}")"

codex_saved="$(bash "$STRATEGY_SCRIPT" "$codex_pane_pid")"
claude_saved="$(bash "$STRATEGY_SCRIPT" "$claude_pane_pid")"

if echo "$codex_saved" | grep -q 'resume_codex_session.sh' && \
   echo "$codex_saved" | grep -q "$codex_session_id"; then
    echo "✓ codex pane resolved to resumable command with session id"
else
    echo "✗ codex pane did not resolve to resumable command"
    echo "$codex_saved"
    exit 1
fi

if echo "$claude_saved" | grep -q 'resume_claude_session.sh' && \
   echo "$claude_saved" | grep -q "$claude_session_id"; then
    echo "✓ claude pane resolved to resumable command with session id"
else
    echo "✗ claude pane did not resolve to resumable command"
    echo "$claude_saved"
    exit 1
fi

echo "=== Agent session resurrect strategy test passed ==="
