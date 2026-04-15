#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Agent session resurrect save stress ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
SAVE_WRAPPER="$PROJECT_ROOT/scripts/resurrect_save.sh"
REAL_RESURRECT_DIR="$HOME/.tmux/plugins/tmux-resurrect"

export TABBY_TMUX_REAL="${TABBY_TMUX_REAL:-$(command -v tmux)}"
source "$PROJECT_ROOT/tests/lib/tmux_test_env.sh"
tabby_init_tmux_test_env "tabby-tests-agent-resurrect-stress"

TEST_SESSION="tabby-agent-resurrect-stress"
TEST_HOME="$(mktemp -d /tmp/tabby-agent-stress-home.XXXXXX)"
TEST_BIN="$(mktemp -d /tmp/tabby-agent-stress-bin.XXXXXX)"
STATE_DB="$TEST_HOME/codex-state.sqlite"
CLAUDE_PROJECTS="$TEST_HOME/claude-projects"
XDG_DATA_HOME="$TEST_HOME/.local/share"
mkdir -p "$CLAUDE_PROJECTS"

cleanup() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    tabby_cleanup_tmux_test_env
    rm -rf "$TEST_HOME" "$TEST_BIN"
}
trap cleanup EXIT

cat > "$TEST_BIN/claude" <<'EOF'
#!/usr/bin/env bash
sleep 120
EOF
chmod +x "$TEST_BIN/claude"

cat > "$TEST_BIN/codex.js" <<'EOF'
setInterval(() => {}, 1000);
EOF

sqlite3 "$STATE_DB" 'create table threads(id text, cwd text, updated_at integer, title text);'

export PATH="$TEST_BIN:$PATH"
export HOME="$TEST_HOME"
export XDG_DATA_HOME
export TABBY_TMUX_RESURRECT_DIR="$REAL_RESURRECT_DIR"
export TABBY_CODEX_STATE_DB="$STATE_DB"
export TABBY_CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS"

tmux new-session -d -s "$TEST_SESSION" -n seed

for i in $(seq 1 6); do
    codir="$(mktemp -d /tmp/tabby-agent-stress-codex.$i.XXXXXX)"
    cldir="$(mktemp -d /tmp/tabby-agent-stress-claude.$i.XXXXXX)"
    sqlite3 "$STATE_DB" "insert into threads(id, cwd, updated_at, title) values('codex-stress-$i', '$codir', $(date +%s), 'stress');"
    claude_project_dir="$CLAUDE_PROJECTS/$(printf '%s' "$cldir" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$claude_project_dir"
    printf '{"type":"custom-title","sessionId":"claude-stress-%s"}\n' "$i" > "$claude_project_dir/claude-stress-$i.jsonl"

    tmux new-window -t "$TEST_SESSION:" -n "codex-$i" -c "$codir"
    tmux send-keys -t "$TEST_SESSION:codex-$i" "node $TEST_BIN/codex.js --no-alt-screen stress-$i" C-m
    tmux new-window -t "$TEST_SESSION:" -n "claude-$i" -c "$cldir"
    tmux send-keys -t "$TEST_SESSION:claude-$i" "$TEST_BIN/claude stress-$i" C-m
done
sleep 1

tmux set-environment -g HOME "$TEST_HOME"
tmux set-environment -g XDG_DATA_HOME "$XDG_DATA_HOME"
tmux set-environment -g PATH "$TEST_BIN:$PATH"
tmux set-environment -g TABBY_TMUX_RESURRECT_DIR "$REAL_RESURRECT_DIR"
tmux set-environment -g TABBY_CODEX_STATE_DB "$STATE_DB"
tmux set-environment -g TABBY_CLAUDE_PROJECTS_DIR "$CLAUDE_PROJECTS"
tmux set-option -g @resurrect-processes '"~resume_codex_session.sh" "~resume_claude_session.sh"'

start_ns="$(date +%s%N)"
for _ in $(seq 1 5); do
    bash "$SAVE_WRAPPER"
done
end_ns="$(date +%s%N)"
total_ms="$(( (end_ns - start_ns) / 1000000 ))"

SAVE_FILE="$TEST_HOME/.tmux/resurrect/last"
[ -f "$SAVE_FILE" ] || SAVE_FILE="$XDG_DATA_HOME/tmux/resurrect/last"
[ -f "$SAVE_FILE" ] || { echo "✗ stress save file missing"; exit 1; }

codex_count="$(grep -c 'resume_codex_session.sh' "$SAVE_FILE" || true)"
claude_count="$(grep -c 'resume_claude_session.sh' "$SAVE_FILE" || true)"

if [ "$codex_count" -eq 6 ] && [ "$claude_count" -eq 6 ]; then
    echo "✓ stress save captured all agent panes"
else
    echo "✗ stress save missed agent panes"
    echo "codex_count=$codex_count claude_count=$claude_count"
    cat "$SAVE_FILE"
    exit 1
fi

if [ "$total_ms" -lt 20000 ]; then
    echo "✓ repeated saves completed in ${total_ms}ms"
else
    echo "✗ repeated saves were too slow (${total_ms}ms)"
    exit 1
fi

echo "=== Agent session resurrect save stress test passed ==="
