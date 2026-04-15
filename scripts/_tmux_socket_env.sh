#!/usr/bin/env bash

# Ensure Tabby processes consistently target the intended tmux server.
# Supports explicit override via TABBY_TMUX_SOCKET.

tabby_runtime_prefix_for_socket() {
    local socket_path="${1:-}"
    if [ -z "$socket_path" ]; then
        printf '%s' "${TABBY_RUNTIME_PREFIX:-}"
        return
    fi
    printf 'sock-%s-' "$(printf '%s' "$socket_path" | cksum | awk '{print $1}')"
}

tabby_init_tmux_socket_env() {
    local current_dir="${1:-}"
    local wrapper_path=""
    local resolved=""

    if [ -n "$current_dir" ]; then
        wrapper_path="$current_dir/bin/tmux"
    fi

    if [ -z "${TABBY_TMUX_REAL:-}" ]; then
        for candidate in /usr/bin/tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
            if [ -x "$candidate" ]; then
                resolved="$candidate"
                break
            fi
        done
        if [ -z "$resolved" ]; then
            resolved="$(command -v tmux 2>/dev/null || true)"
        fi
        if [ -n "$resolved" ] && [ -n "$wrapper_path" ]; then
            if [ "$(readlink -f "$resolved" 2>/dev/null || echo "$resolved")" = "$(readlink -f "$wrapper_path" 2>/dev/null || echo "$wrapper_path")" ]; then
                resolved=""
            fi
        fi
        if [ -z "$resolved" ]; then
            resolved="/usr/bin/tmux"
        fi
        TABBY_TMUX_REAL="$resolved"
        export TABBY_TMUX_REAL
    fi

    if [ -n "$current_dir" ] && [ -d "$current_dir/bin" ]; then
        case ":$PATH:" in
            *":$current_dir/bin:"*) ;;
            *) export PATH="$current_dir/bin:$PATH" ;;
        esac
    fi

    local socket_path
    socket_path="$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)"
    if [ -n "$socket_path" ]; then
        # When running inside tmux, the active server's socket path is the source
        # of truth. This avoids inheriting a stale TABBY_TMUX_SOCKET from an outer
        # shell when tests or nested tmux servers use a different socket.
        export TABBY_TMUX_SOCKET="$socket_path"
    elif [ -n "${TABBY_TMUX_SOCKET:-}" ]; then
        export TABBY_TMUX_SOCKET
    fi

    if [ -n "${TABBY_TMUX_SOCKET:-}" ]; then
        export TABBY_RUNTIME_PREFIX="$(tabby_runtime_prefix_for_socket "$TABBY_TMUX_SOCKET")"
        tmux set-environment -g TABBY_RUNTIME_PREFIX "$TABBY_RUNTIME_PREFIX" >/dev/null 2>&1 || true
    fi
}
