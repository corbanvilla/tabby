#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
VERSION_PKG="github.com/brendandebeasi/tabby/pkg/version.Version"

if ! command -v go >/dev/null 2>&1; then
	echo "Go is not installed. Please install Go 1.24+ from https://go.dev/doc/install"
	exit 1
fi

mkdir -p "$PLUGIN_DIR/bin"

cd "$PLUGIN_DIR"

if [ -z "${VERSION:-}" ]; then
	if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
		VERSION="$GITHUB_REF_NAME"
	else
		VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
	fi
fi

GO_LDFLAGS=(-ldflags "-X ${VERSION_PKG}=${VERSION}")

go build "${GO_LDFLAGS[@]}" -o bin/render-status ./cmd/render-status
go build "${GO_LDFLAGS[@]}" -o bin/render-tab ./cmd/render-tab
go build "${GO_LDFLAGS[@]}" -o bin/tabby-daemon ./cmd/tabby-daemon
go build "${GO_LDFLAGS[@]}" -o bin/sidebar-renderer ./cmd/sidebar-renderer
go build "${GO_LDFLAGS[@]}" -o bin/pane-header ./cmd/pane-header
go build "${GO_LDFLAGS[@]}" -o bin/cycle-pane ./cmd/cycle-pane
go build "${GO_LDFLAGS[@]}" -o bin/new-window ./cmd/new-window
go build "${GO_LDFLAGS[@]}" -o bin/manage-group ./cmd/manage-group

chmod +x bin/render-status
chmod +x bin/render-tab
chmod +x bin/tabby-daemon
chmod +x bin/sidebar-renderer
chmod +x bin/pane-header
chmod +x bin/cycle-pane
chmod +x bin/new-window
chmod +x bin/manage-group
chmod +x scripts/toggle_sidebar.sh

printf "Installation complete (%s). Reload tmux config with: tmux source ~/.tmux.conf\n" "$VERSION"
