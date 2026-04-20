#!/usr/bin/env bash

# Resolve the single Tabby owner session for a set of grouped tmux windows.
# tmux grouped sessions share window IDs, so keying daemon runtime only by the
# current session ID can start duplicate daemons for the same windows.

tabby_canonical_session_id() {
    local target="${1:-}"

    if [ -z "$target" ]; then
        target="$(tmux display-message -p '#{session_id}' 2>/dev/null || echo "")"
    fi
    [ -n "$target" ] || return 1

    local target_windows
    target_windows="$(tmux list-windows -t "$target" -F '#{window_id}' 2>/dev/null | tr '\n' ' ')"
    if [ -z "$target_windows" ]; then
        printf '%s\n' "$target"
        return 0
    fi

    local owner
    # Use stable tmux session identity. Attachment state changes as clients move
    # between grouped sessions; using it here would move the daemon owner.
    owner="$(
        tmux list-windows -a -F '#{session_id}|#{session_created}|#{window_id}' 2>/dev/null \
            | awk -F'|' -v windows="$target_windows" '
                BEGIN {
                    split(windows, ids, " ")
                    for (i in ids) {
                        if (ids[i] != "") wanted[ids[i]] = 1
                    }
                }
                wanted[$3] {
                    sid = $1
                    if (!(sid in seen)) {
                        seen[sid] = 1
                        created[sid] = $2 + 0
                    }
                }
                END {
                    for (sid in seen) {
                        numeric_sid = sid
                        sub(/^\$/, "", numeric_sid)
                        printf "%d %d %s\n", created[sid], numeric_sid + 0, sid
                    }
                }
            ' \
            | LC_ALL=C sort -k1,1n -k2,2n \
            | awk '{ print $3; exit }'
    )"

    printf '%s\n' "${owner:-$target}"
}

tabby_is_canonical_session() {
    local target="${1:-}"
    local owner

    owner="$(tabby_canonical_session_id "$target")" || return 1
    [ "$target" = "$owner" ]
}
