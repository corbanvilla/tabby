#!/usr/bin/env bash

tabby_live_require_tmux() {
    local candidate wrapper_path wrapper_real candidate_real

    wrapper_path="${PROJECT_ROOT:-}/bin/tmux"
    wrapper_real=""
    if [ -n "${PROJECT_ROOT:-}" ] && [ -e "$wrapper_path" ]; then
        wrapper_real="$(readlink -f "$wrapper_path" 2>/dev/null || echo "$wrapper_path")"
    fi

    for candidate in "${TABBY_LIVE_TMUX_REAL:-}" /usr/bin/tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux "$(command -v tmux 2>/dev/null || true)"; do
        [ -n "$candidate" ] || continue
        [ -x "$candidate" ] || continue
        candidate_real="$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")"
        if [ -n "$wrapper_real" ] && [ "$candidate_real" = "$wrapper_real" ]; then
            continue
        fi
        TABBY_LIVE_TMUX_REAL="$candidate"
        break
    done

    export TABBY_LIVE_TMUX_REAL
    if [ -z "$TABBY_LIVE_TMUX_REAL" ]; then
        echo "a real tmux binary is required for this test"
        return 1
    fi
}

tabby_live_tmx() {
    "$TABBY_LIVE_TMUX_REAL" -L "$TABBY_LIVE_SOCKET" -f /dev/null "$@"
}

tabby_live_seed_env() {
    local socket_path
    socket_path="$(tabby_live_tmx display-message -p '#{socket_path}')"
    tabby_live_tmx set-environment -g TABBY_TMUX_SOCKET "$socket_path"
    tabby_live_tmx set-environment -g TABBY_TMUX_REAL "$TABBY_LIVE_TMUX_REAL"
    export TABBY_TMUX_SOCKET="$socket_path"
    export TABBY_TMUX_REAL="$TABBY_LIVE_TMUX_REAL"
}

tabby_live_wait_for() {
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

tabby_live_start_attached_client() {
    local session="$1"
    local label="$2"
    local tty_dump="/tmp/tabby-live-${label}-tty-$$.typescript"
    local log_file="/tmp/tabby-live-${label}-client-$$.log"
    TERM=xterm script -q -c "TERM=xterm $TABBY_LIVE_TMUX_REAL -L $TABBY_LIVE_SOCKET -f /dev/null attach-session -t $session" "$tty_dump" >"$log_file" 2>&1 &
    local pid=$!
    TABBY_LIVE_CLIENT_PIDS="${TABBY_LIVE_CLIENT_PIDS:-} $pid"
    export TABBY_LIVE_CLIENT_PIDS
    if ! tabby_live_wait_for 30 bash -lc "'$TABBY_LIVE_TMUX_REAL' -L '$TABBY_LIVE_SOCKET' -f /dev/null list-clients -F '#{session_name}' 2>/dev/null | grep -qx '$session'"; then
        echo "failed to attach client for $session"
        [ -f "$log_file" ] && sed -n '1,80p' "$log_file" || true
        return 1
    fi
}

tabby_live_stop_clients() {
    local pid
    for pid in ${TABBY_LIVE_CLIENT_PIDS:-}; do
        kill "$pid" >/dev/null 2>&1 || true
    done
}

tabby_live_session_has_sidebar() {
    local session="$1"
    tabby_live_tmx list-panes -s -t "$session" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
        | grep -Eq "(sidebar-renderer|sidebar)"
}

tabby_live_window_has_sidebar() {
    local target="$1"
    tabby_live_tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
        | grep -Eq "(sidebar-renderer|sidebar)"
}

tabby_live_enable_sidebar_for_session() {
    local session="$1"
    local attempt
    for attempt in 1 2 3; do
        tabby_live_tmx set-option -g @tabby_sidebar disabled
        tabby_live_tmx run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
        if tabby_live_wait_for 50 tabby_live_session_has_sidebar "$session"; then
            return 0
        fi
        tabby_live_tmx run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh"
        sleep 0.5
    done
    return 1
}

tabby_live_enable_sidebar_for_window() {
    local session="$1"
    local target="$2"
    local session_id=""
    local attempt
    session_id="$(tabby_live_tmx display-message -p -t "$session:" '#{session_id}' 2>/dev/null || true)"
    for attempt in 1 2 3; do
        if tabby_live_wait_for 40 tabby_live_window_has_sidebar "$target"; then
            return 0
        fi
        if [ -n "$session_id" ]; then
            TABBY_TMUX_SOCKET="$TABBY_TMUX_SOCKET" TABBY_TMUX_REAL="$TABBY_TMUX_REAL" \
                "$PROJECT_ROOT/scripts/signal_sidebar.sh" "$session_id" >/dev/null 2>&1 || true
        fi
        tabby_live_tmx run-shell -b -t "$session:" "$PROJECT_ROOT/scripts/ensure_sidebar.sh _ \"$target\""
        sleep 0.4
    done
    return 1
}

tabby_live_sidebar_pane_for_window() {
    local target="$1"
    tabby_live_tmx list-panes -t "$target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
        | awk -F'|' '$2 ~ /(sidebar|sidebar-renderer)/ || $3 ~ /(sidebar|sidebar-renderer)/ {print $1; exit}'
}

tabby_live_content_pane_for_window() {
    local target="$1"
    tabby_live_tmx list-panes -t "$target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}|#{pane_active}" 2>/dev/null \
        | awk -F'|' '$2 !~ /(sidebar|sidebar-renderer|pane-header|tabby-daemon)/ && $3 !~ /(sidebar|sidebar-renderer|pane-header|tabby-daemon)/ && $4 == "1" {print $1; found=1; exit} END {if (!found) print ""}' \
        | { read -r pane; if [ -n "$pane" ]; then printf '%s\n' "$pane"; else tabby_live_tmx list-panes -t "$target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
            | awk -F'|' '$2 !~ /(sidebar|sidebar-renderer|pane-header|tabby-daemon)/ && $3 !~ /(sidebar|sidebar-renderer|pane-header|tabby-daemon)/ {print $1; exit}'; fi; }
}

tabby_live_last_content_pane_for_window() {
    local target="$1"
    tabby_live_tmx list-panes -t "$target" -F "#{pane_id}|#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
        | awk -F'|' '$2 !~ /(sidebar|sidebar-renderer|pane-header|tabby-daemon)/ && $3 !~ /(sidebar|sidebar-renderer|pane-header|tabby-daemon)/ {pane=$1} END {print pane}'
}

tabby_live_sidebar_width_for_window() {
    local target="$1"
    local pane
    pane="$(tabby_live_sidebar_pane_for_window "$target")"
    [ -n "$pane" ] || return 1
    tabby_live_tmx display-message -p -t "$pane" '#{pane_width}'
}

tabby_live_content_width_for_window() {
    local target="$1"
    local pane
    pane="$(tabby_live_content_pane_for_window "$target")"
    [ -n "$pane" ] || return 1
    tabby_live_tmx display-message -p -t "$pane" '#{pane_width}'
}

tabby_live_renderer_count_for_window() {
    local target="$1"
    tabby_live_tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
        | awk '$1 ~ /(sidebar-renderer|sidebar)/ || $2 ~ /(sidebar-renderer|sidebar)/ {count++} END {print count+0}'
}

tabby_live_content_count_for_window() {
    local target="$1"
    tabby_live_tmx list-panes -t "$target" -F "#{pane_current_command}|#{pane_start_command}" 2>/dev/null \
        | awk '$1 !~ /(sidebar-renderer|sidebar|pane-header|tabby-daemon)/ && $2 !~ /(sidebar-renderer|sidebar|pane-header|tabby-daemon)/ {count++} END {print count+0}'
}

tabby_live_client_tty() {
    tabby_live_tmx list-clients -F "#{client_tty}" 2>/dev/null | head -1
}

tabby_live_resize_client() {
    local tty="$1"
    local size="$2"
    local target="${3:-$(tabby_live_tmx display-message -p '#{window_id}')}"
    local width="${size%x*}"
    local height="${size#*x}"
    local session_id
    session_id="$(tabby_live_tmx display-message -p '#{session_id}')"
    tabby_live_tmx resize-window -t "$target" -x "$width" -y "$height"
    "$PROJECT_ROOT/scripts/stabilize_client_resize.sh" "$session_id" "$target" >/dev/null 2>&1 || true
    "$PROJECT_ROOT/scripts/signal_sidebar.sh" "$session_id" >/dev/null 2>&1 || true
}
