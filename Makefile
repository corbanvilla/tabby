.PHONY: build test test-e2e test-live test-unit test-race test-cover vet ci capture-visual compare-visual update-baseline clean install test-release

# Go parameters
GOCMD=go
GOBUILD=$(GOCMD) build
GOTEST=$(GOCMD) test
GOMOD=$(GOCMD) mod
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
GO_LDFLAGS=-ldflags "-X github.com/brendandebeasi/tabby/pkg/version.Version=$(VERSION)"

# Binary names
RENDER_STATUS=bin/render-status
RENDER_TAB=bin/render-tab
TABBY_DAEMON=bin/tabby-daemon
SIDEBAR_RENDERER=bin/sidebar-renderer
PANE_HEADER=bin/pane-header
MANAGE_GROUP=bin/manage-group
NEW_WINDOW=bin/new-window

# Directories
BIN_DIR=bin
TEST_DIR=tests
E2E_DIR=$(TEST_DIR)/e2e
SCREENSHOT_DIR=$(TEST_DIR)/screenshots

# Default target
all: build

# Build all binaries
build: $(RENDER_STATUS) $(RENDER_TAB) $(TABBY_DAEMON) $(SIDEBAR_RENDERER) $(PANE_HEADER) $(MANAGE_GROUP) $(NEW_WINDOW)

$(RENDER_STATUS): cmd/render-status/main.go pkg/**/*.go
	@mkdir -p $(BIN_DIR)
	$(GOBUILD) $(GO_LDFLAGS) -o $@ ./cmd/render-status

$(RENDER_TAB): cmd/render-tab/main.go
	@mkdir -p $(BIN_DIR)
	$(GOBUILD) $(GO_LDFLAGS) -o $@ ./cmd/render-tab

$(TABBY_DAEMON): cmd/tabby-daemon/*.go pkg/**/*.go
	@mkdir -p $(BIN_DIR)
	$(GOBUILD) $(GO_LDFLAGS) -o $@ ./cmd/tabby-daemon

$(SIDEBAR_RENDERER): cmd/sidebar-renderer/main.go pkg/**/*.go
	@mkdir -p $(BIN_DIR)
	$(GOBUILD) $(GO_LDFLAGS) -o $@ ./cmd/sidebar-renderer

$(PANE_HEADER): cmd/pane-header/main.go pkg/**/*.go
	@mkdir -p $(BIN_DIR)
	$(GOBUILD) $(GO_LDFLAGS) -o $@ ./cmd/pane-header

$(MANAGE_GROUP): cmd/manage-group/main.go pkg/**/*.go
	@mkdir -p $(BIN_DIR)
	$(GOBUILD) $(GO_LDFLAGS) -o $@ ./cmd/manage-group

$(NEW_WINDOW): cmd/new-window/main.go pkg/**/*.go
	@mkdir -p $(BIN_DIR)
	$(GOBUILD) $(GO_LDFLAGS) -o $@ ./cmd/new-window

# Download dependencies
deps:
	$(GOMOD) download
	$(GOMOD) tidy

# Run all tests
test: test-unit test-e2e

# Run unit tests
test-unit:
	$(GOTEST) -v ./pkg/...

# Run all Go unit tests with race detector
test-race:
	$(GOTEST) -race ./...

# Run tests with coverage profile and per-function report
test-cover:
	$(GOTEST) -coverprofile=coverage.out -covermode=atomic ./...
	$(GOCMD) tool cover -func=coverage.out

# Run static analysis
vet:
	$(GOCMD) vet ./...

# Full CI check: vet + race tests + coverage
ci: vet test-race test-cover

# Run E2E tests
test-e2e: build
	@$(E2E_DIR)/run_e2e.sh

# Run live tmux integration test (isolated sockets + attached pseudo-clients)
test-live: build
	@bash $(TEST_DIR)/integration/live_tmux_sessions_test.sh
	@bash $(TEST_DIR)/integration/live_socket_override_test.sh
	@bash $(TEST_DIR)/integration/live_multiclient_same_session_test.sh
	@bash $(TEST_DIR)/integration/window_exit_orphan_cleanup_test.sh
	@bash $(TEST_DIR)/integration/new_window_quick_exit_cleanup_test.sh
	@bash $(TEST_DIR)/integration/window_kill_focus_matrix_test.sh
	@bash $(TEST_DIR)/integration/background_window_exit_stability_test.sh
	@bash $(TEST_DIR)/integration/live_header_singleton_resilience_test.sh
	@bash $(TEST_DIR)/integration/live_pane_bell_mock_app_test.sh
	@bash $(TEST_DIR)/integration/live_sidebar_singleton_names_test.sh
	@bash $(TEST_DIR)/integration/sidebar_width_sync_test.sh
	@bash $(TEST_DIR)/integration/terminal_resize_convergence_test.sh
	@bash $(TEST_DIR)/integration/sidebar_refresh_hooks_test.sh
	@bash $(TEST_DIR)/integration/live_toggle_concurrency_test.sh
	@bash $(TEST_DIR)/integration/live_trajectory_matrix_test.sh
	@bash $(TEST_DIR)/integration/live_resize_trajectory_stress_test.sh
	@bash $(TEST_DIR)/integration/live_seeded_fuzz_trajectory_test.sh
	@bash $(TEST_DIR)/integration/resurrect_integration_test.sh
	@bash $(TEST_DIR)/integration/resurrect_autosave_integration_test.sh
	@bash $(TEST_DIR)/integration/agent_session_resurrect_strategy_test.sh
	@bash $(TEST_DIR)/integration/agent_session_resurrect_e2e_test.sh
	@bash $(TEST_DIR)/integration/agent_session_resurrect_stress_test.sh

test-release: build
	$(GOTEST) ./...
	@$(E2E_DIR)/run_e2e.sh
	@$(MAKE) test-live
	@TABBY_RUN_REAL_AGENT_SMOKE=$(TABBY_RUN_REAL_AGENT_SMOKE) bash $(TEST_DIR)/integration/real_agent_session_resurrect_smoke_test.sh

# Capture visual screenshots
capture-visual: build
	@$(E2E_DIR)/capture_visual.sh

# Compare visual screenshots with baseline
compare-visual: build
	@$(E2E_DIR)/capture_visual.sh

# Update baseline screenshots
update-baseline: build
	@$(E2E_DIR)/capture_visual.sh --update-baseline

# Plugin install directory (override with: make install PLUGIN_DIR=~/custom/path)
PLUGIN_DIR ?= $(HOME)/.tmux/plugins/tabby

# Install to tmux plugins directory
install: build
	@echo "Installing to $(PLUGIN_DIR)/"
	@mkdir -p $(PLUGIN_DIR)/bin
	@mkdir -p $(PLUGIN_DIR)/scripts
	@mkdir -p ~/.config/tabby
	@cp $(RENDER_STATUS) $(PLUGIN_DIR)/bin/
	@cp $(RENDER_TAB) $(PLUGIN_DIR)/bin/
	@cp $(TABBY_DAEMON) $(PLUGIN_DIR)/bin/
	@cp $(SIDEBAR_RENDERER) $(PLUGIN_DIR)/bin/
	@cp $(PANE_HEADER) $(PLUGIN_DIR)/bin/
	@cp $(MANAGE_GROUP) $(PLUGIN_DIR)/bin/
	@cp $(NEW_WINDOW) $(PLUGIN_DIR)/bin/
	@cp scripts/*.sh $(PLUGIN_DIR)/scripts/
	@cp tabby.tmux $(PLUGIN_DIR)/
	@test -f ~/.config/tabby/config.yaml || cp config.yaml ~/.config/tabby/config.yaml
	@chmod +x $(PLUGIN_DIR)/bin/*
	@chmod +x $(PLUGIN_DIR)/scripts/*
	@chmod +x $(PLUGIN_DIR)/tabby.tmux
	@echo "Installation complete. Reload tmux config with: tmux source ~/.tmux.conf"

# Sync development to install location
sync: build
	@cp $(RENDER_STATUS) $(PLUGIN_DIR)/bin/
	@cp $(RENDER_TAB) $(PLUGIN_DIR)/bin/
	@cp $(TABBY_DAEMON) $(PLUGIN_DIR)/bin/
	@cp $(SIDEBAR_RENDERER) $(PLUGIN_DIR)/bin/
	@cp $(PANE_HEADER) $(PLUGIN_DIR)/bin/
	@cp $(MANAGE_GROUP) $(PLUGIN_DIR)/bin/
	@cp $(NEW_WINDOW) $(PLUGIN_DIR)/bin/
	@cp scripts/*.sh $(PLUGIN_DIR)/scripts/
	@cp tabby.tmux $(PLUGIN_DIR)/
	@test -f ~/.config/tabby/config.yaml || cp config.yaml ~/.config/tabby/config.yaml
	@echo "Synced to $(PLUGIN_DIR)/ (config -> ~/.config/tabby/)"

# Clean build artifacts
clean:
	@rm -rf $(BIN_DIR)
	@rm -f $(SCREENSHOT_DIR)/current/*
	@rm -f $(SCREENSHOT_DIR)/diffs/*

# Clean everything including baseline
clean-all: clean
	@rm -f $(SCREENSHOT_DIR)/baseline/*

# Run in development mode (rebuild on change)
dev: build
	@echo "Development mode - rebuild with 'make build'"
	@echo "Sync changes with 'make sync'"

# Show help
help:
	@echo "Tabby Makefile targets:"
	@echo ""
	@echo "  build          - Build all binaries"
	@echo "  test           - Run all tests (unit + E2E)"
	@echo "  test-unit      - Run Go unit tests"
	@echo "  test-e2e       - Run E2E integration tests"
	@echo "  test-live      - Run live tmux server/session integration test"
	@echo "  capture-visual - Capture visual screenshots"
	@echo "  update-baseline- Update baseline screenshots"
	@echo "  install        - Install binaries + config (~/.config/tabby/config.yaml)"
	@echo "  sync           - Sync dev changes to install location"
	@echo "  clean          - Remove build artifacts"
	@echo "  deps           - Download Go dependencies"
	@echo ""
