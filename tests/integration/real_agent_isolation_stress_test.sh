#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Real agent indicator isolation stress ==="

if [ "${TABBY_RUN_REAL_AGENT_ISOLATION_STRESS:-0}" != "1" ]; then
    echo "Skipping real agent isolation stress test (set TABBY_RUN_REAL_AGENT_ISOLATION_STRESS=1 to enable)"
    exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux || true)"
if [ -z "$tmux_real" ] || ! command -v script >/dev/null 2>&1; then
    echo "Skipping real agent isolation stress test (tmux and script(1) are required)"
    exit 0
fi

codex_available() {
    command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1
}

claude_available() {
    local claude_bin="${TABBY_CLAUDE_BIN:-claude}"
    command -v "$claude_bin" >/dev/null 2>&1 && "$claude_bin" auth status >/dev/null 2>&1
}

if ! codex_available || ! claude_available; then
    echo "Skipping real agent isolation stress test (Codex and Claude must both be available)"
    exit 0
fi

SOCKET_PATH="$(mktemp -u /tmp/tabby-real-agent-isolation.XXXXXX.sock)"
SESSION="tabby-real-agent-isolation"
CLIENT_PID=""
TEST_DIR="$(mktemp -d /tmp/tabby-real-agent-isolation.XXXXXX)"
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
    local i
    for i in $(seq 1 "$tries"); do
        if "$@"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

start_attached_client() {
    local tty_dump="/tmp/tabby-real-agent-isolation-$$.typescript"
    local log_file="/tmp/tabby-real-agent-isolation-$$.log"
    env -u TMUX TERM=xterm \
        TABBY_CONFIG_DIR="$TABBY_TEST_CONFIG_DIR" \
        TABBY_STATE_DIR="$TABBY_TEST_STATE_DIR" \
        TABBY_TMUX_REAL="$tmux_real" \
        TABBY_TMUX_SOCKET="$SOCKET_PATH" \
        script -q -c "env -u TMUX TERM=xterm TABBY_CONFIG_DIR='$TABBY_TEST_CONFIG_DIR' TABBY_STATE_DIR='$TABBY_TEST_STATE_DIR' TABBY_TMUX_REAL='$tmux_real' TABBY_TMUX_SOCKET='$SOCKET_PATH' '$tmux_real' -S '$SOCKET_PATH' -f /dev/null attach-session -t '$SESSION'" "$tty_dump" >"$log_file" 2>&1 &
    CLIENT_PID=$!
    wait_for 60 bash -lc "'$tmux_real' -S '$SOCKET_PATH' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$SESSION'"
}

sidebar_pane() {
    tmx list-panes -a -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null |
        awk -F'|' '$2 ~ /(sidebar-renderer|sidebar)/ || $3 ~ /(sidebar-renderer|sidebar)/ {print $1; exit}'
}

sidebar_capture() {
    local pane
    pane="$(sidebar_pane)"
    [ -n "$pane" ] || return 1
    tmx capture-pane -p -t "$pane" -S -200
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

sidebar_contains() {
    local text="$1"
    local capture
    signal_sidebar
    capture="$(sidebar_capture 2>/dev/null || true)"
    [[ "$capture" == *"$text"* ]]
}

window_line() {
    local name="$1"
    sidebar_capture 2>/dev/null | grep -F "$name" | head -n 1 || true
}

window_has_state() {
    local name="$1"
    local state="$2"
    local line
    signal_sidebar
    line="$(window_line "$name")"
    [[ "$line" == *"$state"* ]]
}

window_lacks_busy() {
    local name="$1"
    window_lacks_state "$name" "BUSY"
}

window_lacks_state() {
    local name="$1"
    local state="$2"
    local line
    signal_sidebar
    line="$(window_line "$name")"
    [ -n "$line" ] && [[ "$line" != *"$state"* ]]
}

window_lacks_input() {
    local name="$1"
    window_lacks_state "$name" "INPUT"
}

window_pane() {
    local name="$1"
    local window_id
    window_id="$(tmx list-windows -F '#{window_name}|#{window_id}' | awk -F'|' -v name="$name" '$1 == name {print $2; exit}')"
    [ -n "$window_id" ] || return 1
    tmx list-panes -t "$window_id" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" |
        awk -F'|' '$2 !~ /(sidebar-renderer|sidebar|pane-header|tabby-daemon)/ && $3 !~ /(sidebar-renderer|sidebar|pane-header|tabby-daemon)/ {print $1; exit}'
}

paste_line_to_pane() {
    local pane="$1"
    local text="$2"
    tmx set-buffer "$text"
    tmx paste-buffer -t "$pane"
    sleep 0.3
    tmx send-keys -t "$pane" Enter
}

switch_to_watch_window() {
    tmx select-window -t "$SESSION:watch"
    signal_sidebar
}

view_agent_window() {
    local name="$1"
    local pane
    pane="$(window_pane "$name")"
    tmx select-window -t "$SESSION:$name"
    [ -n "$pane" ] && tmx select-pane -t "$pane"
    signal_sidebar
}

setup_session() {
    tmx start-server
    tmx new-session -d -s "$SESSION" -n cdx-a -c "$PROJECT_ROOT" 'exec bash -l'
    tmx new-window -d -t "$SESSION:" -n cdx-b -c "$PROJECT_ROOT" 'exec bash -l'
    tmx new-window -d -t "$SESSION:" -n cld-a -c "$PROJECT_ROOT" 'exec bash -l'
    if command -v fish >/dev/null 2>&1; then
        tmx new-window -d -t "$SESSION:" -n fish -c "$PROJECT_ROOT" 'exec fish -l'
    else
        tmx new-window -d -t "$SESSION:" -n fish -c "$PROJECT_ROOT" 'exec bash -l'
    fi
    tmx new-window -d -t "$SESSION:" -n watch -c "$PROJECT_ROOT" 'exec bash -l'
    tmx set-environment -g TABBY_CONFIG_DIR "$TABBY_TEST_CONFIG_DIR"
    tmx set-environment -g TABBY_STATE_DIR "$TABBY_TEST_STATE_DIR"
    tmx set-environment -g TABBY_TMUX_REAL "$tmux_real"
    tmx set-environment -g TABBY_TMUX_SOCKET "$SOCKET_PATH"
    start_attached_client

    tmx run-shell -b "$PROJECT_ROOT/tabby.tmux"
    sleep 1
    tmx set-option -g @tabby_sidebar disabled
    tmx set-option -g @tabby_sidebar_position left
    tmx set-option -g @tabby_sidebar_mode full
    tmx set-option -g @tabby_pane_headers off
    tmx set-option -g @tabby_auto_rename off
    tmx rename-window -t "$SESSION:0" cdx-a
    tmx rename-window -t "$SESSION:1" cdx-b
    tmx rename-window -t "$SESSION:2" cld-a
    tmx rename-window -t "$SESSION:3" fish
    tmx rename-window -t "$SESSION:4" watch
    tmx run-shell -b -t "$SESSION:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
    if ! wait_for 100 sidebar_contains "cdx-a" ||
        ! wait_for 100 sidebar_contains "cdx-b" ||
        ! wait_for 100 sidebar_contains "cld-a" ||
        ! wait_for 100 sidebar_contains "fish"; then
        echo "✗ sidebar did not render all stress windows"
        tmx list-panes -a -F "#{window_name}|#{pane_id}|#{pane_current_command}|#{pane_start_command}" || true
        sidebar_capture || true
        return 1
    fi
}

wait_for_busy_then_input_window() {
    local name="$1"
    local saw_busy=0
    local i
    for i in $(seq 1 600); do
        if window_has_state "$name" "BUSY"; then
            saw_busy=1
        fi
        if [ "$saw_busy" = "1" ] && window_has_state "$name" "INPUT"; then
            return 0
        fi
        sleep 0.2
    done
    echo "✗ $name did not show BUSY then INPUT"
    sidebar_capture || true
    return 1
}

wait_for_isolated_busy() {
    local busy_name="$1"
    shift
    local other i ok other_name
    for i in $(seq 1 300); do
        ok=1
        window_has_state "$busy_name" "BUSY" || ok=0
        for other_name in "$@"; do
            window_lacks_busy "$other_name" || ok=0
        done
        if [ "$ok" = "1" ]; then
            return 0
        fi
        sleep 0.2
    done
    echo "✗ busy state was not isolated to $busy_name"
    sidebar_capture || true
    return 1
}

wait_for_all_input() {
    local i ok name
    for i in $(seq 1 300); do
        ok=1
        for name in "$@"; do
            window_has_state "$name" "INPUT" || ok=0
        done
        if [ "$ok" = "1" ]; then
            return 0
        fi
        sleep 0.2
    done
    echo "✗ expected INPUT on: $*"
    sidebar_capture || true
    return 1
}

wait_for_input_ack_isolated() {
    local viewed_name="$1"
    shift
    local i ok name
    view_agent_window "$viewed_name"
    for i in $(seq 1 300); do
        ok=1
        window_lacks_input "$viewed_name" || ok=0
        for name in "$@"; do
            window_has_state "$name" "INPUT" || ok=0
        done
        if [ "$ok" = "1" ]; then
            switch_to_watch_window
            return 0
        fi
        sleep 0.2
    done
    echo "✗ viewing $viewed_name did not clear only that INPUT marker"
    sidebar_capture || true
    return 1
}

wait_for_inputs_and_no_busy() {
    local i ok name
    for i in $(seq 1 300); do
        ok=1
        for name in "$@"; do
            window_has_state "$name" "INPUT" || ok=0
            window_lacks_busy "$name" || ok=0
        done
        if [ "$ok" = "1" ]; then
            return 0
        fi
        sleep 0.2
    done
    echo "✗ expected INPUT without BUSY on: $*"
    sidebar_capture || true
    return 1
}

launch_codex() {
    local name="$1"
    local pane nonce prompt prompt_q cmd
    pane="$(window_pane "$name")"
    nonce="tabby-${name}-initial-$(date +%s)-$$"
    prompt="Reply with exactly $nonce and no other text."
    printf -v prompt_q '%q' "$prompt"
    cmd="codex --no-alt-screen --ask-for-approval never --sandbox read-only $prompt_q"
    tmx send-keys -t "$pane" -l "$cmd"
    tmx send-keys -t "$pane" C-m
    switch_to_watch_window
    wait_for_busy_then_input_window "$name"
}

launch_claude() {
    local name="$1"
    local pane nonce prompt claude_bin claude_bin_q
    pane="$(window_pane "$name")"
    nonce="tabby-${name}-initial-$(date +%s)-$$"
    prompt="Reply with exactly $nonce and no other text."
    claude_bin="${TABBY_CLAUDE_BIN:-claude}"
    printf -v claude_bin_q '%q' "$claude_bin"
    tmx send-keys -t "$pane" -l "$claude_bin_q --dangerously-skip-permissions --tools \"\""
    tmx send-keys -t "$pane" C-m
    if ! wait_for 300 bash -lc "'$tmux_real' -S '$SOCKET_PATH' -f /dev/null display-message -p -t '$pane' '#{pane_current_command}' 2>/dev/null | grep -qx claude"; then
        echo "✗ Claude command did not start"
        tmx capture-pane -p -t "$pane" -S -120 | tail -n 80 || true
        return 1
    fi
    if ! wait_for 300 bash -lc "'$tmux_real' -S '$SOCKET_PATH' -f /dev/null capture-pane -p -t '$pane' -S -120 2>/dev/null | grep -Fq bypass"; then
        echo "✗ Claude prompt did not become ready"
        tmx capture-pane -p -t "$pane" -S -120 | tail -n 80 || true
        return 1
    fi
    paste_line_to_pane "$pane" "$prompt"
    switch_to_watch_window
    wait_for_busy_then_input_window "$name"
}

send_agent_prompt() {
    local name="$1"
    local pane nonce prompt
    pane="$(window_pane "$name")"
    nonce="tabby-${name}-round-$(date +%s)-$$"
    prompt="Reply with exactly $nonce and no other text."
    paste_line_to_pane "$pane" "$prompt"
    switch_to_watch_window
}

setup_session
launch_codex cdx-a
launch_codex cdx-b
launch_claude cld-a

wait_for_all_input cdx-a cdx-b cld-a
wait_for_input_ack_isolated cdx-a cdx-b cld-a
wait_for_input_ack_isolated cdx-b cld-a

if ! wait_for 80 window_lacks_busy fish; then
    echo "✗ fish window unexpectedly showed BUSY"
    sidebar_capture || true
    exit 1
fi
if ! wait_for 80 window_lacks_input fish; then
    echo "✗ fish window unexpectedly showed INPUT"
    sidebar_capture || true
    exit 1
fi

send_agent_prompt cdx-a
wait_for_isolated_busy cdx-a cdx-b cld-a fish
wait_for_inputs_and_no_busy cld-a
wait_for_busy_then_input_window cdx-a
wait_for_inputs_and_no_busy cdx-a cld-a

send_agent_prompt cdx-b
wait_for_isolated_busy cdx-b cdx-a cld-a fish
wait_for_inputs_and_no_busy cdx-a cld-a
wait_for_busy_then_input_window cdx-b
wait_for_inputs_and_no_busy cdx-a cdx-b cld-a

echo "=== Real agent indicator isolation stress test passed ==="
