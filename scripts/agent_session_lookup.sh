#!/usr/bin/env bash
set -euo pipefail

tabby_child_pid_for_pane() {
    local pane_pid="${1:-}"
    [ -n "$pane_pid" ] || return 1
    pgrep -P "$pane_pid" | head -n1
}

tabby_pane_metadata_by_pid() {
    local pane_pid="${1:-}"
    [ -n "$pane_pid" ] || return 1
    tmux list-panes -a -F "#{pane_pid}\t#{pane_current_path}\t#{pane_current_command}" 2>/dev/null \
        | awk -F '\t' -v pid="$pane_pid" '$1 == pid { print $2 "\t" $3; exit }'
}

tabby_process_started_at_epoch() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    local elapsed
    elapsed="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$elapsed" ] || return 1
    printf '%s\n' "$(( $(date +%s) - elapsed ))"
}

tabby_raw_command_for_pid() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    ps -o args= -p "$pid" 2>/dev/null
}

tabby_sql_escape() {
    printf '%s' "${1:-}" | sed "s/'/''/g"
}

tabby_find_codex_session_id() {
    local cwd="${1:-}"
    local started_at="${2:-0}"
    local db_path="${TABBY_CODEX_STATE_DB:-$HOME/.codex/state_5.sqlite}"
    [ -n "$cwd" ] || return 1
    [ -f "$db_path" ] || return 1

    local escaped_cwd lower_bound
    escaped_cwd="$(tabby_sql_escape "$cwd")"
    lower_bound="$started_at"
    if [ "$lower_bound" -gt 90 ]; then
        lower_bound="$((lower_bound - 90))"
    else
        lower_bound=0
    fi

    sqlite3 "$db_path" \
        "select id from threads where cwd='$escaped_cwd' and updated_at >= $lower_bound order by updated_at desc limit 1;" \
        2>/dev/null \
        | head -n1
}

tabby_claude_project_key() {
    printf '%s' "${1:-}" | sed 's/[^A-Za-z0-9]/-/g'
}

tabby_find_claude_session_id() {
    local cwd="${1:-}"
    local started_at="${2:-0}"
    local projects_dir="${TABBY_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    [ -n "$cwd" ] || return 1

    local project_dir lower_bound
    project_dir="$projects_dir/$(tabby_claude_project_key "$cwd")"
    [ -d "$project_dir" ] || return 1

    lower_bound="$started_at"
    if [ "$lower_bound" -gt 90 ]; then
        lower_bound="$((lower_bound - 90))"
    else
        lower_bound=0
    fi

    find "$project_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@|%f\n' 2>/dev/null \
        | awk -F '|' -v lower="$lower_bound" '$1 + 0 >= lower { print $0 }' \
        | sort -t '|' -k1,1nr \
        | head -n1 \
        | cut -d '|' -f2 \
        | sed 's/\.jsonl$//'
}
