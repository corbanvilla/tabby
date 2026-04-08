#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Socket + Hook Portability Guards ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
TABBY_TMUX="$PROJECT_ROOT/bin/tmux"
SOCKET_ENV="$PROJECT_ROOT/scripts/_tmux_socket_env.sh"
SIGNAL_SCRIPT="$PROJECT_ROOT/scripts/signal_sidebar.sh"
RESTORE_SCRIPT="$PROJECT_ROOT/scripts/restore_sidebar.sh"
FOCUS_SCRIPT="$PROJECT_ROOT/scripts/focus_new_window.sh"
TOGGLE_SCRIPT="$PROJECT_ROOT/scripts/toggle_sidebar.sh"
TOGGLE_DAEMON_SCRIPT="$PROJECT_ROOT/scripts/toggle_sidebar_daemon.sh"
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
check_bootstrap "$RESTORE_SCRIPT" "restore_sidebar.sh"
check_bootstrap "$FOCUS_SCRIPT" "focus_new_window.sh"
check_bootstrap "$TOGGLE_SCRIPT" "toggle_sidebar.sh"
check_bootstrap "$TOGGLE_DAEMON_SCRIPT" "toggle_sidebar_daemon.sh"

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
