#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
source "$SCRIPT_DIR/agent_session_lookup.sh"

pane_pid="${1:-}"
[ -n "$pane_pid" ] || exit 0

child_pid="$(tabby_child_pid_for_pane "$pane_pid" 2>/dev/null || true)"
raw_command=""
started_at=0
if [ -n "$child_pid" ]; then
    raw_command="$(tabby_raw_command_for_pid "$child_pid" 2>/dev/null || true)"
    started_at="$(tabby_process_started_at_epoch "$child_pid" 2>/dev/null || echo 0)"
fi

cwd=""
if [ -n "$child_pid" ] && [ -L "/proc/$child_pid/cwd" ]; then
    cwd="$(readlink -f "/proc/$child_pid/cwd" 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$(readlink -f "/proc/$pane_pid/cwd" 2>/dev/null || true)"

if [ -n "$cwd" ]; then
    if printf '%s' "$raw_command" | grep -Eq '(^|[ /])claude( |$)'; then
        session_id="$(tabby_find_claude_session_id "$cwd" "$started_at" 2>/dev/null || true)"
        if [ -n "$session_id" ]; then
            printf '%q %q\n' "$SCRIPT_DIR/resume_claude_session.sh" "$session_id"
            exit 0
        fi
    fi

    if printf '%s' "$raw_command" | grep -Eq 'codex(\.js)?([[:space:]]|$)|@openai\+codex|/codex/bin/codex\.js'; then
        session_id="$(tabby_find_codex_session_id "$cwd" "$started_at" 2>/dev/null || true)"
        if [ -n "$session_id" ]; then
            cmd=( "$SCRIPT_DIR/resume_codex_session.sh" )
            if printf '%s' "$raw_command" | grep -q -- '--no-alt-screen'; then
                cmd+=( "--no-alt-screen" )
            fi
            cmd+=( "$session_id" )
            printf '%q ' "${cmd[@]}"
            printf '\n'
            exit 0
        fi
    fi
fi

if [ -n "$child_pid" ]; then
    printf '%s\n' "$raw_command"
fi
