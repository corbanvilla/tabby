#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Live socket override routing ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
tmux_real="$(command -v tmux)"

if [ -z "$tmux_real" ]; then
  echo "tmux is required for this test"
  exit 1
fi

SOCK_A="$(mktemp -u /tmp/tabby-live-sock-a.XXXXXX)"
SOCK_B="$(mktemp -u /tmp/tabby-live-sock-b.XXXXXX)"
SESSION_A="sock-a"
SESSION_B="sock-b"

cleanup() {
  "$tmux_real" -S "$SOCK_A" -f /dev/null kill-server >/dev/null 2>&1 || true
  "$tmux_real" -S "$SOCK_B" -f /dev/null kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$tmux_real" -S "$SOCK_A" -f /dev/null start-server
"$tmux_real" -S "$SOCK_A" -f /dev/null new-session -d -s "$SESSION_A" -n "main-a"
"$tmux_real" -S "$SOCK_B" -f /dev/null start-server
"$tmux_real" -S "$SOCK_B" -f /dev/null new-session -d -s "$SESSION_B" -n "main-b"

out_a="$(TABBY_TMUX_SOCKET="$SOCK_A" TABBY_TMUX_REAL="$tmux_real" "$PROJECT_ROOT/bin/tmux" list-sessions -F "#{session_name}" | sort)"
out_b="$(TABBY_TMUX_SOCKET="$SOCK_B" TABBY_TMUX_REAL="$tmux_real" "$PROJECT_ROOT/bin/tmux" list-sessions -F "#{session_name}" | sort)"

if echo "$out_a" | grep -qx "$SESSION_A" && ! echo "$out_a" | grep -qx "$SESSION_B"; then
  echo "✓ bin/tmux routed to socket A only"
else
  echo "✗ bin/tmux socket A routing failed"
  echo "socket A sessions seen:"
  echo "$out_a"
  exit 1
fi

if echo "$out_b" | grep -qx "$SESSION_B" && ! echo "$out_b" | grep -qx "$SESSION_A"; then
  echo "✓ bin/tmux routed to socket B only"
else
  echo "✗ bin/tmux socket B routing failed"
  echo "socket B sessions seen:"
  echo "$out_b"
  exit 1
fi

TABBY_TMUX_SOCKET="$SOCK_A" TABBY_TMUX_REAL="$tmux_real" \
  "$PROJECT_ROOT/bin/tmux" set-option -g @tabby_socket_override_live "value-a"
TABBY_TMUX_SOCKET="$SOCK_B" TABBY_TMUX_REAL="$tmux_real" \
  "$PROJECT_ROOT/bin/tmux" set-option -g @tabby_socket_override_live "value-b"

val_a="$("$tmux_real" -S "$SOCK_A" -f /dev/null show-option -gqv @tabby_socket_override_live || true)"
val_b="$("$tmux_real" -S "$SOCK_B" -f /dev/null show-option -gqv @tabby_socket_override_live || true)"

if [ "$val_a" = "value-a" ] && [ "$val_b" = "value-b" ]; then
  echo "✓ socket-specific option writes stayed isolated"
else
  echo "✗ socket-specific option writes leaked across servers"
  echo "A value: $val_a"
  echo "B value: $val_b"
  exit 1
fi

socket_env_probe="$(
  TABBY_TMUX_SOCKET="$SOCK_A" TABBY_TMUX_REAL="$tmux_real" PROJECT_ROOT="$PROJECT_ROOT" bash -lc '
    set -euo pipefail
    source "$PROJECT_ROOT/scripts/_tmux_socket_env.sh"
    tabby_init_tmux_socket_env "$PROJECT_ROOT"
    tmux list-sessions -F "#{session_name}" | sort
  '
)"

if echo "$socket_env_probe" | grep -qx "$SESSION_A" && ! echo "$socket_env_probe" | grep -qx "$SESSION_B"; then
  echo "✓ _tmux_socket_env bootstrap honored override socket"
else
  echo "✗ _tmux_socket_env bootstrap did not honor override socket"
  echo "$socket_env_probe"
  exit 1
fi

echo "=== Live socket override routing test passed ==="
