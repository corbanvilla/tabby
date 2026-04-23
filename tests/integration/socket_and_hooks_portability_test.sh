#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Socket + Hook Portability Guards ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
TABBY_TMUX="$PROJECT_ROOT/bin/tmux"
SOCKET_ENV="$PROJECT_ROOT/scripts/_tmux_socket_env.sh"
SIGNAL_SCRIPT="$PROJECT_ROOT/scripts/signal_sidebar.sh"
INDICATOR_SCRIPT="$PROJECT_ROOT/scripts/set-tabby-indicator.sh"
RESTORE_SCRIPT="$PROJECT_ROOT/scripts/restore_sidebar.sh"
FOCUS_SCRIPT="$PROJECT_ROOT/scripts/focus_new_window.sh"
RESIZE_SCRIPT="$PROJECT_ROOT/scripts/resize_sidebar.sh"
STABILIZE_SCRIPT="$PROJECT_ROOT/scripts/stabilize_client_resize.sh"
TOGGLE_SCRIPT="$PROJECT_ROOT/scripts/toggle_sidebar.sh"
TOGGLE_DAEMON_SCRIPT="$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
WATCHDOG_SCRIPT="$PROJECT_ROOT/scripts/watchdog_daemon.sh"
NEW_WINDOW_SCRIPT="$PROJECT_ROOT/scripts/new_window_with_group.sh"
APPLY_GROUP_SCRIPT="$PROJECT_ROOT/scripts/apply_new_window_group.sh"
PLUGIN_TMUX="$PROJECT_ROOT/tabby.tmux"

check_bootstrap() {
  local script="$1"
  local label="$2"
  if grep -q 'source "\$CURRENT_DIR/scripts/_tmux_socket_env.sh"' "$script" && \
     grep -q 'tabby_init_tmux_socket_env "\$CURRENT_DIR"' "$script"; then
    echo "✓ $label bootstraps tmux socket env"
  else
    echo "✗ $label missing tmux socket env bootstrap"
    exit 1
  fi
}

if [ -x "$TABBY_TMUX" ] && grep -q 'TABBY_TMUX_SOCKET' "$TABBY_TMUX"; then
  echo "✓ bin/tmux wrapper is present and socket-aware"
else
  echo "✗ bin/tmux wrapper missing or not socket-aware"
  exit 1
fi

if [ -f "$SOCKET_ENV" ] && grep -q 'TABBY_TMUX_SOCKET' "$SOCKET_ENV"; then
  echo "✓ _tmux_socket_env helper defines socket handling"
else
  echo "✗ _tmux_socket_env helper missing socket handling"
  exit 1
fi

check_bootstrap "$SIGNAL_SCRIPT" "signal_sidebar.sh"
check_bootstrap "$INDICATOR_SCRIPT" "set-tabby-indicator.sh"
check_bootstrap "$RESTORE_SCRIPT" "restore_sidebar.sh"
check_bootstrap "$FOCUS_SCRIPT" "focus_new_window.sh"
check_bootstrap "$RESIZE_SCRIPT" "resize_sidebar.sh"
check_bootstrap "$STABILIZE_SCRIPT" "stabilize_client_resize.sh"
check_bootstrap "$TOGGLE_SCRIPT" "toggle_sidebar.sh"
check_bootstrap "$TOGGLE_DAEMON_SCRIPT" "toggle_sidebar_daemon.sh"
check_bootstrap "$NEW_WINDOW_SCRIPT" "new_window_with_group.sh"
check_bootstrap "$APPLY_GROUP_SCRIPT" "apply_new_window_group.sh"

if [ -x "$APPLY_GROUP_SCRIPT" ]; then
  echo "✓ apply_new_window_group.sh is packaged as an executable script"
else
  echo "✗ apply_new_window_group.sh missing or not executable"
  exit 1
fi

if git -C "$PROJECT_ROOT" check-ignore -q scripts/apply_new_window_group.sh; then
  echo "✗ apply_new_window_group.sh is ignored and can be omitted from releases"
  exit 1
else
  echo "✓ apply_new_window_group.sh is not ignored by git"
fi

if git -C "$PROJECT_ROOT" ls-files --error-unmatch scripts/apply_new_window_group.sh >/dev/null 2>&1 || \
   git -C "$PROJECT_ROOT" ls-files --others --exclude-standard | grep -qx 'scripts/apply_new_window_group.sh'; then
  echo "✓ apply_new_window_group.sh is tracked or addable for release archives"
else
  echo "✗ apply_new_window_group.sh is not tracked or addable for release archives"
  exit 1
fi

if grep -Fq 'CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"' "$NEW_WINDOW_SCRIPT"; then
  echo "✓ new_window_with_group.sh resolves CURRENT_DIR at runtime"
else
  echo "✗ new_window_with_group.sh has a baked-in CURRENT_DIR"
  exit 1
fi

if grep -Fq 'CURRENT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"' "$PLUGIN_TMUX"; then
  echo "✓ tabby.tmux generates new_window_with_group.sh with runtime CURRENT_DIR"
else
  echo "✗ tabby.tmux new-window template expands CURRENT_DIR while sourcing"
  exit 1
fi

if grep -Fq 'cat > "$APPLY_GROUP_SCRIPT"' "$PLUGIN_TMUX"; then
  echo "✗ tabby.tmux still generates apply_new_window_group.sh instead of packaging it"
  exit 1
else
  echo "✓ tabby.tmux does not generate apply_new_window_group.sh at runtime"
fi

if grep -Fq 'if [ -x \"$APPLY_GROUP_SCRIPT\" ]; then \"$APPLY_GROUP_SCRIPT\" \"#{window_id}\"; fi' "$PLUGIN_TMUX"; then
  echo "✓ after-new-window hook guards apply_new_window_group.sh"
else
  echo "✗ after-new-window hook does not guard apply_new_window_group.sh"
  exit 1
fi

if grep -Fq 'tabby_config_value "swap_pane"' "$PLUGIN_TMUX" && \
   ! grep -Eq 'grep "(toggle_sidebar|next_window_global|prev_window_global|new_window_global|kill_window_global|swap_pane|swap_window_next|swap_window_prev):"' "$PLUGIN_TMUX"; then
  echo "✓ key binding config reads ignore comments"
else
  echo "✗ key binding config reads can parse commented bindings"
  exit 1
fi

if grep -q 'tmux set-option -g @tabby_daemon_pid "$DAEMON_PID"' "$WATCHDOG_SCRIPT"; then
  echo "✓ watchdog publishes daemon pid for tmux hooks after every start"
else
  echo "✗ watchdog does not refresh @tabby_daemon_pid"
  exit 1
fi

if grep -Fq 'DAEMON_PID_FILE="/tmp/${RUNTIME_PREFIX}tabby-daemon-${SESSION_ID}.pid"' "$INDICATOR_SCRIPT"; then
  echo "✓ set-tabby-indicator signals socket-prefixed daemon pid files"
else
  echo "✗ set-tabby-indicator does not signal socket-prefixed daemon pid files"
  exit 1
fi

if grep -q "\\[ -x \".*cycle-pane\" \\] &&" "$PLUGIN_TMUX" || \
   grep -q "\\[ -x \".*cycle-pane\" \\] &&" "$TOGGLE_DAEMON_SCRIPT"; then
  echo "✗ legacy '[ -x ... ] && ...' cycle-pane hook remains (causes tmux 'returned 1' noise)"
  exit 1
fi

if grep -q 'if \[ -x .*CYCLE_PANE_BIN.*\]; then .*CYCLE_PANE_BIN.*--dim-only; fi' "$PLUGIN_TMUX" && \
   grep -q 'if \[ -x .*CYCLE_PANE_BIN.*\]; then .*CYCLE_PANE_BIN.*--dim-only; fi' "$TOGGLE_DAEMON_SCRIPT"; then
  echo "✓ cycle-pane hooks use non-noisy conditional form"
else
  echo "✗ cycle-pane hooks missing non-noisy conditional form"
  exit 1
fi

echo "=== Socket + Hook Portability Guards test passed ==="
