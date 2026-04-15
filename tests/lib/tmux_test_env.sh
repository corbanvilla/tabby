#!/usr/bin/env bash

tabby_init_tmux_test_env() {
    local default_socket_name="${1:-tabby-tests}"

    if [ -z "${TABBY_TEST_SOCKET:-}" ]; then
        TABBY_TEST_SOCKET="$default_socket_name"
        export TABBY_TEST_SOCKET
    fi

    if [ -z "${TABBY_TEST_SOCKET_PATH:-}" ]; then
        case "$TABBY_TEST_SOCKET" in
            /*) TABBY_TEST_SOCKET_PATH="$TABBY_TEST_SOCKET" ;;
            *) TABBY_TEST_SOCKET_PATH="/tmp/${TABBY_TEST_SOCKET}.sock" ;;
        esac
        export TABBY_TEST_SOCKET_PATH
    fi

    if [ -z "${TABBY_TMUX_REAL:-}" ]; then
        local candidate
        for candidate in /usr/bin/tmux /bin/tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
            if [ -x "$candidate" ]; then
                TABBY_TMUX_REAL="$candidate"
                export TABBY_TMUX_REAL
                break
            fi
        done
        if [ -z "${TABBY_TMUX_REAL:-}" ]; then
            TABBY_TMUX_REAL="$(command -v tmux)"
            export TABBY_TMUX_REAL
        fi
    fi

    if [ -z "${TABBY_TMUX_WRAPPER_DIR:-}" ] || [ ! -x "${TABBY_TMUX_WRAPPER_DIR:-}/tmux" ]; then
        TABBY_TMUX_WRAPPER_DIR="$(mktemp -d /tmp/tabby-tests-tmux.XXXXXX)"
        export TABBY_TMUX_WRAPPER_DIR
        cat > "$TABBY_TMUX_WRAPPER_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$TABBY_TMUX_REAL" -S "$TABBY_TEST_SOCKET_PATH" -f /dev/null "\$@"
EOF
        chmod +x "$TABBY_TMUX_WRAPPER_DIR/tmux"
    fi

    case ":$PATH:" in
        *":$TABBY_TMUX_WRAPPER_DIR:"*) ;;
        *) export PATH="$TABBY_TMUX_WRAPPER_DIR:$PATH" ;;
    esac

    export TABBY_TMUX_SOCKET="$TABBY_TEST_SOCKET_PATH"
    export TABBY_TMUX_WRAPPED=1
}

tabby_cleanup_tmux_test_env() {
    if [ -n "${TABBY_TMUX_WRAPPER_DIR:-}" ] && [ -d "${TABBY_TMUX_WRAPPER_DIR:-}" ]; then
        rm -rf "$TABBY_TMUX_WRAPPER_DIR"
    fi
}

tmux() {
    command tmux "$@"
}
