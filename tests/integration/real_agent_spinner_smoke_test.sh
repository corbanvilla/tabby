#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Real agent spinner smoke ==="

if [ "${TABBY_RUN_REAL_AGENT_SPINNER_SMOKE:-0}" != "1" ]; then
    echo "Skipping real agent spinner smoke test (set TABBY_RUN_REAL_AGENT_SPINNER_SMOKE=1 to enable)"
    exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux || true)"
if [ -z "$tmux_real" ] || ! command -v script >/dev/null 2>&1; then
    echo "Skipping real agent spinner smoke test (tmux and script(1) are required)"
    exit 0
fi

SOCKET_PATH="$(mktemp -u /tmp/tabby-real-agent-spinner.XXXXXX.sock)"
SESSION="tabby-real-agent-spinner"
CLIENT_PID=""
TEST_DIR="$(mktemp -d /tmp/tabby-real-agent-spinner.XXXXXX)"
TABBY_TEST_CONFIG_DIR="$TEST_DIR/config"
TABBY_TEST_STATE_DIR="$TEST_DIR/state"
mkdir -p "$TABBY_TEST_CONFIG_DIR" "$TABBY_TEST_STATE_DIR"

cat >"$TABBY_TEST_CONFIG_DIR/config.yaml" <<'YAML'
theme: default
groups:
  - name: "Default"
    pattern: ".*"
    theme:
      bg: "#56949f"
      active_bg: "#286983"
      icon: "*"
widgets:
  clock:
    enabled: false
  stats:
    enabled: false
  pet:
    enabled: false
busy_detection:
  ai_tools:
    - codex
    - claude
  idle_timeout: 1
indicators:
  bell:
    enabled: true
    icon: "BELL"
    color: "#ffcc00"
  busy:
    enabled: true
    frames: ["BUSY"]
    color: "#00aaff"
  input:
    enabled: true
    icon: "INPUT"
    frames: ["INPUT"]
    color: "#ff00aa"
YAML

tmx() {
    env -u TMUX \
        TABBY_CONFIG_DIR="$TABBY_TEST_CONFIG_DIR" \
        TABBY_STATE_DIR="$TABBY_TEST_STATE_DIR" \
        TABBY_TMUX_REAL="$tmux_real" \
        TABBY_TMUX_SOCKET="$SOCKET_PATH" \
        "$tmux_real" -S "$SOCKET_PATH" -f /dev/null "$@"
}

cleanup() {
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" >/dev/null 2>&1 || true
    tmx kill-server >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR" "$SOCKET_PATH" >/dev/null 2>&1 || true
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
        sleep 0.2
    done
    return 1
}

start_attached_client() {
    local label="$1"
    local tty_dump="/tmp/tabby-real-agent-spinner-${label}-$$.typescript"
    local log_file="/tmp/tabby-real-agent-spinner-${label}-$$.log"
    env -u TMUX TERM=xterm \
        TABBY_CONFIG_DIR="$TABBY_TEST_CONFIG_DIR" \
        TABBY_STATE_DIR="$TABBY_TEST_STATE_DIR" \
        TABBY_TMUX_REAL="$tmux_real" \
        TABBY_TMUX_SOCKET="$SOCKET_PATH" \
        script -q -c "env -u TMUX TERM=xterm TABBY_CONFIG_DIR='$TABBY_TEST_CONFIG_DIR' TABBY_STATE_DIR='$TABBY_TEST_STATE_DIR' TABBY_TMUX_REAL='$tmux_real' TABBY_TMUX_SOCKET='$SOCKET_PATH' '$tmux_real' -S '$SOCKET_PATH' -f /dev/null attach-session -t '$SESSION'" "$tty_dump" >"$log_file" 2>&1 &
    CLIENT_PID=$!
    wait_for 60 bash -lc "'$tmux_real' -S '$SOCKET_PATH' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"
}

session_has_sidebar() {
    tmx list-panes -a -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null | grep -Eq "(sidebar-renderer|sidebar)"
}

sidebar_pane() {
    local pane
    pane="$(tmx list-panes -t "$SESSION:" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null |
        awk -F'|' '$2 ~ /(sidebar-renderer|sidebar)/ || $3 ~ /(sidebar-renderer|sidebar)/ {print $1; exit}')"
    if [ -n "$pane" ]; then
        printf '%s\n' "$pane"
        return 0
    fi
    tmx list-panes -a -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null |
        awk -F'|' '$2 ~ /(sidebar-renderer|sidebar)/ || $3 ~ /(sidebar-renderer|sidebar)/ {print $1; exit}'
}

content_pane() {
    tmx list-panes -a -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null |
        awk -F'|' '$2 !~ /(sidebar-renderer|sidebar|pane-header|tabby-daemon)/ && $3 !~ /(sidebar-renderer|sidebar|pane-header|tabby-daemon)/ {print $1; exit}'
}

switch_to_watch_window() {
    tmx new-window -d -t "$SESSION:" -n watch -c "$PROJECT_ROOT" 'exec bash -l' >/dev/null 2>&1 || true
    tmx select-window -t "$SESSION:watch"
    tmx switch-client -t "$SESSION:watch" >/dev/null 2>&1 || true
    wait_for 80 bash -lc "'$tmux_real' -S '$SOCKET_PATH' -f /dev/null display-message -p -t '$SESSION:' '#W' 2>/dev/null | grep -qx watch"
    signal_sidebar
    wait_for 80 sidebar_contains "Default"
}

sidebar_capture() {
    local pane
    pane="$(sidebar_pane)"
    [ -n "$pane" ] || return 1
    tmx capture-pane -p -t "$pane" -S -200
}

sidebar_contains() {
    local text="$1"
    local capture
    signal_sidebar
    capture="$(sidebar_capture 2>/dev/null || true)"
    [[ "$capture" == *"$text"* ]]
}

signal_sidebar() {
    local session_id
    session_id="$(tmx display-message -p -t "$SESSION:" '#{session_id}' 2>/dev/null || true)"
    [ -n "$session_id" ] || return 0
    env -u TMUX \
        TABBY_CONFIG_DIR="$TABBY_TEST_CONFIG_DIR" \
        TABBY_STATE_DIR="$TABBY_TEST_STATE_DIR" \
        TABBY_TMUX_REAL="$tmux_real" \
        TABBY_TMUX_SOCKET="$SOCKET_PATH" \
        "$PROJECT_ROOT/scripts/signal_sidebar.sh" "$session_id" >/dev/null 2>&1 || true
}

setup_sidebar_session() {
    local label="$1"
    [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" >/dev/null 2>&1 || true
    CLIENT_PID=""
    tmx kill-server >/dev/null 2>&1 || true
    rm -f "$SOCKET_PATH" >/dev/null 2>&1 || true

    tmx start-server
    tmx new-session -d -s "$SESSION" -n "$label" -c "$PROJECT_ROOT" 'exec bash -l'
    tmx set-environment -g TABBY_CONFIG_DIR "$TABBY_TEST_CONFIG_DIR"
    tmx set-environment -g TABBY_STATE_DIR "$TABBY_TEST_STATE_DIR"
    tmx set-environment -g TABBY_TMUX_REAL "$tmux_real"
    tmx set-environment -g TABBY_TMUX_SOCKET "$SOCKET_PATH"
    start_attached_client "$label"

    tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
    sleep 1
    tmx set-option -g @tabby_sidebar disabled
    tmx set-option -g @tabby_sidebar_position left
    tmx set-option -g @tabby_sidebar_mode full
    tmx set-option -g @tabby_pane_headers off
    tmx set-option -g @tabby_auto_rename off
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if ! wait_for 80 session_has_sidebar; then
        echo "✗ sidebar did not start for $label"
        tmx list-panes -a -F "#{pane_id} cmd=#{pane_current_command} start=#{pane_start_command}" || true
        return 1
    fi
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
    if ! wait_for 80 sidebar_contains "Default"; then
        echo "✗ sidebar did not render window list before agent launch"
        sidebar_capture || true
        return 1
    fi
}

wait_for_busy_then_input() {
    local label="$1"
    local pane="$2"
    local saw_busy=0
    local capture title command
    local i
    for i in $(seq 1 600); do
        signal_sidebar
        capture="$(sidebar_capture 2>/dev/null || true)"
        title="$(tmx display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)"
        command="$(tmx display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)"

        if [[ "$capture" == *"BUSY"* ]]; then
            saw_busy=1
        fi
        if [ "$saw_busy" = "1" ] && [[ "$capture" == *"INPUT"* ]]; then
            echo "✓ $label showed BUSY then INPUT"
            return 0
        fi
        sleep 0.2
    done

    echo "✗ $label did not show BUSY then INPUT"
    echo "saw_busy=$saw_busy command=$command title=$title"
    echo "--- sidebar ---"
    printf '%s\n' "$capture"
    echo "--- pane tail ---"
    tmx capture-pane -p -t "$pane" -S -120 | tail -n 80 || true
    return 1
}

wait_for_pane_contains() {
    local pane="$1"
    local text="$2"
    local i
    for i in $(seq 1 300); do
        if tmx capture-pane -p -t "$pane" -S -200 | grep -Fq "$text"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

paste_line_to_pane() {
    local pane="$1"
    local text="$2"
    tmx set-buffer "$text"
    tmx paste-buffer -t "$pane"
    sleep 0.3
    tmx send-keys -t "$pane" Enter
}

codex_available() {
    command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1
}

claude_available() {
    local claude_bin="${TABBY_CLAUDE_BIN:-claude}"
    command -v "$claude_bin" >/dev/null 2>&1 && "$claude_bin" auth status >/dev/null 2>&1
}

run_codex_smoke() {
    setup_sidebar_session "codex" || return 1
    local pane nonce prompt cmd
    pane="$(content_pane)"
    [ -n "$pane" ] || { echo "✗ failed to find Codex content pane"; return 1; }
    nonce="tabby-codex-spinner-$(date +%s)-$$"
    prompt="Use the shell to run: sleep 2; echo $nonce. Then reply with exactly $nonce and no other text."
    cmd="codex --dangerously-bypass-approvals-and-sandbox"
    tmx send-keys -t "$pane" -l "$cmd"
    tmx send-keys -t "$pane" C-m
    if ! wait_for 300 bash -lc "'$tmux_real' -S '$SOCKET_PATH' -f /dev/null display-message -p -t '$pane' '#{pane_current_command}' 2>/dev/null | grep -qx node"; then
        echo "✗ Codex command did not start"
        tmx capture-pane -p -t "$pane" -S -120 | tail -n 80 || true
        return 1
    fi
    if tmx capture-pane -p -t "$pane" -S -120 2>/dev/null | grep -Fq "Do you trust"; then
        tmx send-keys -t "$pane" C-m
    fi
    if ! wait_for_pane_contains "$pane" "OpenAI Codex"; then
        echo "✗ Codex prompt did not become ready"
        tmx capture-pane -p -t "$pane" -S -120 | tail -n 80 || true
        return 1
    fi
    paste_line_to_pane "$pane" "$prompt"
    switch_to_watch_window || { echo "✗ failed to switch away from Codex pane"; return 1; }
    wait_for_busy_then_input "Codex" "$pane" || return 1
    if wait_for_pane_contains "$pane" "$nonce"; then
        echo "✓ Codex pane rendered expected nonce"
    else
        echo "i Codex TUI did not leave nonce in tmux scrollback after spinner transition"
    fi
}

run_claude_smoke() {
    setup_sidebar_session "claude" || return 1
    local pane nonce prompt claude_bin claude_bin_q
    pane="$(content_pane)"
    [ -n "$pane" ] || { echo "✗ failed to find Claude content pane"; return 1; }
    nonce="tabby-claude-spinner-$(date +%s)-$$"
    prompt="Use the shell to run: sleep 2; echo $nonce. Then reply with exactly $nonce and no other text."
    claude_bin="${TABBY_CLAUDE_BIN:-claude}"
    printf -v claude_bin_q '%q' "$claude_bin"
    tmx send-keys -t "$pane" -l "$claude_bin_q --dangerously-skip-permissions --tools \"\""
    tmx send-keys -t "$pane" C-m
    if ! wait_for 300 bash -lc "'$tmux_real' -S '$SOCKET_PATH' -f /dev/null display-message -p -t '$pane' '#{pane_current_command}' 2>/dev/null | grep -qx claude"; then
        echo "✗ Claude command did not start"
        tmx capture-pane -p -t "$pane" -S -120 | tail -n 80 || true
        return 1
    fi
    if ! wait_for_pane_contains "$pane" "bypass"; then
        echo "✗ Claude prompt did not become ready"
        tmx capture-pane -p -t "$pane" -S -120 | tail -n 80 || true
        return 1
    fi
    paste_line_to_pane "$pane" "$prompt"
    switch_to_watch_window || { echo "✗ failed to switch away from Claude pane"; return 1; }
    wait_for_busy_then_input "Claude" "$pane" || return 1
    if wait_for_pane_contains "$pane" "$nonce"; then
        echo "✓ Claude pane rendered expected nonce"
    else
        echo "i Claude TUI did not leave nonce in tmux scrollback after spinner transition"
    fi
}

ran=0
skipped=0
failed=0
for tool in ${TABBY_REAL_AGENT_SPINNER_TOOLS:-codex claude}; do
    case "$tool" in
        codex)
            if codex_available; then
                ran=$((ran + 1))
                run_codex_smoke || failed=$((failed + 1))
            else
                skipped=$((skipped + 1))
                echo "Skipping Codex spinner smoke (codex unavailable or not authenticated)"
            fi
            ;;
        claude)
            if claude_available; then
                ran=$((ran + 1))
                run_claude_smoke || failed=$((failed + 1))
            else
                skipped=$((skipped + 1))
                echo "Skipping Claude spinner smoke (claude unavailable or not authenticated)"
            fi
            ;;
        *)
            echo "Unknown tool in TABBY_REAL_AGENT_SPINNER_TOOLS: $tool" >&2
            failed=$((failed + 1))
            ;;
    esac
done

if [ "$failed" -gt 0 ]; then
    echo "✗ real agent spinner smoke failed ($failed failed, $ran attempted, $skipped skipped)"
    exit 1
fi

if [ "$ran" -eq 0 ]; then
    echo "Skipping real agent spinner smoke (no requested agents were available)"
    exit 0
fi

echo "=== Real agent spinner smoke test passed ($ran attempted, $skipped skipped) ==="
