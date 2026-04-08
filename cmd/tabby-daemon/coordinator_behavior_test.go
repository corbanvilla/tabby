package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/brendandebeasi/tabby/pkg/config"
	"github.com/brendandebeasi/tabby/pkg/daemon"
	"github.com/brendandebeasi/tabby/pkg/grouping"
	"github.com/brendandebeasi/tabby/pkg/tmux"
)

func installFakeTmux(t *testing.T, body string) string {
	t.Helper()

	dir := t.TempDir()
	logPath := filepath.Join(dir, "tmux.log")
	scriptPath := filepath.Join(dir, "tmux")
	if err := os.WriteFile(logPath, nil, 0o644); err != nil {
		t.Fatalf("seed fake tmux log: %v", err)
	}
	script := fmt.Sprintf(`#!/bin/sh
set -eu
printf '%%s\n' "$*" >> %q
%s
`, logPath, body)

	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake tmux: %v", err)
	}

	path := os.Getenv("PATH")
	if path == "" {
		t.Setenv("PATH", dir)
	} else {
		t.Setenv("PATH", dir+string(os.PathListSeparator)+path)
	}

	return logPath
}

func readFileString(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func findMenuItem(items []menuItemDef, label string) (menuItemDef, bool) {
	for _, item := range items {
		if item.Label == label {
			return item, true
		}
	}
	return menuItemDef{}, false
}

func TestExecuteOrSendMenuRoutesByClientType(t *testing.T) {
	logPath := installFakeTmux(t, "exit 0")

	c := newTestCoordinator(t)
	args := []string{"display-menu", "-O", "-T", "Sidebar Settings", "-x", "12", "-y", "5", "Item", "a", "echo hi"}
	pos := menuPosition{PaneID: "%1", X: 12, Y: 5}

	var captured daemon.MenuPayload
	callbackCalls := 0
	c.OnSendMenu = func(clientID string, menu *daemon.MenuPayload) {
		callbackCalls++
		if menu != nil {
			captured = *menu
		}
		if clientID != "client-1" {
			t.Fatalf("unexpected clientID in callback: %s", clientID)
		}
	}

	c.executeOrSendMenu("client-1", args, pos)

	if callbackCalls != 1 {
		t.Fatalf("expected socket callback once, got %d", callbackCalls)
	}
	if captured.Title != "Sidebar Settings" {
		t.Fatalf("unexpected payload title: %q", captured.Title)
	}
	if captured.X != 12 || captured.Y != 5 {
		t.Fatalf("unexpected payload position: (%d,%d)", captured.X, captured.Y)
	}
	if _, ok := c.pendingMenus["client-1"]; !ok {
		t.Fatalf("expected pending menu for client-1")
	}
	if got := c.pendingMenus["client-1"][0].Command; got != "echo hi" {
		t.Fatalf("unexpected pending command: %q", got)
	}
	if got := strings.TrimSpace(readFileString(t, logPath)); got != "" {
		t.Fatalf("expected no tmux fallback for socket client, got log %q", got)
	}

	callbackCalls = 0
	c.executeOrSendMenu("header:%1", args, pos)

	if callbackCalls != 0 {
		t.Fatalf("header client should bypass socket callback, got %d calls", callbackCalls)
	}
	if _, ok := c.pendingMenus["header:%1"]; ok {
		t.Fatalf("header client should not cache pending menu")
	}
	log := readFileString(t, logPath)
	if !strings.Contains(log, "display-menu -O -T Sidebar Settings -x 12 -y 5 Item a echo hi") {
		t.Fatalf("expected tmux fallback log, got %q", log)
	}
}

func TestShowSidebarSettingsMenuGeneratesLifecycleCommands(t *testing.T) {
	c := newTestCoordinator(t)
	c.config.Sidebar.PrefixMode = true
	c.globalWidth = 33
	c.windows = []tmux.Window{
		{
			Index:     7,
			SyncWidth: false,
			Panes:     []tmux.Pane{{ID: "%7"}},
		},
	}

	var payload daemon.MenuPayload
	c.OnSendMenu = func(clientID string, menu *daemon.MenuPayload) {
		if clientID != "client-1" {
			t.Fatalf("unexpected clientID: %s", clientID)
		}
		if menu != nil {
			payload = *menu
		}
	}

	c.showSidebarSettingsMenu("client-1", menuPosition{PaneID: "%7", X: 4, Y: 9})

	if payload.Title != "Sidebar Settings" {
		t.Fatalf("unexpected menu title: %q", payload.Title)
	}

	items := c.pendingMenus["client-1"]
	restartTogglePath := c.getToggleScript()

	left, ok := findMenuItem(items, "Position: Left")
	if !ok {
		t.Fatalf("missing Position: Left menu item")
	}
	if !strings.Contains(left.Command, "set-option -g @tabby_sidebar_position left") {
		t.Fatalf("unexpected left command: %q", left.Command)
	}
	if strings.Count(left.Command, restartTogglePath) != 2 {
		t.Fatalf("expected restart command to reference toggle script twice, got %q", left.Command)
	}

	mode, ok := findMenuItem(items, "Mode: Full Height")
	if !ok {
		t.Fatalf("missing Mode: Full Height menu item")
	}
	if !strings.Contains(mode.Command, "set-option -g @tabby_sidebar_mode full") {
		t.Fatalf("unexpected mode command: %q", mode.Command)
	}

	headers, ok := findMenuItem(items, "Pane Headers: On")
	if !ok {
		t.Fatalf("missing pane headers command")
	}
	if headers.Command != "set-option -g @tabby_pane_headers on" {
		t.Fatalf("unexpected pane headers command: %q", headers.Command)
	}

	prefix, ok := findMenuItem(items, "Display: Prefix Mode")
	if !ok {
		t.Fatalf("missing prefix mode toggle")
	}
	if prefix.Command != "set-option -g @tabby_prefix_mode 0" {
		t.Fatalf("unexpected prefix command: %q", prefix.Command)
	}

	syncWidth, ok := findMenuItem(items, "Sync Width: Off")
	if !ok {
		t.Fatalf("missing sync width toggle")
	}
	wantSync := "set-window-option -t :7 @tabby_sync_width 1 ; run-shell -b 'tmux resize-pane -t %7 -x 33'"
	if syncWidth.Command != wantSync {
		t.Fatalf("unexpected sync width command:\n got %q\nwant %q", syncWidth.Command, wantSync)
	}
}

func TestRefreshSessionUpdatesAndFallsBack(t *testing.T) {
	t.Run("updates_from_tmux", func(t *testing.T) {
		installFakeTmux(t, `
case "$*" in
  *'display-message -p #{session_name}'*) printf '%s\n' 'tabby-dev' ;;
  *'list-clients -t tabby-dev'*) printf '%s\n%s\n' 'client-a' 'client-b' ;;
  *'display-message -p #{session_windows}'*) printf '%s\n' '6' ;;
esac
exit 0
`)

		c := newTestCoordinator(t)
		c.sessionName = "cached-session"
		c.windowCount = 1

		c.RefreshSession()

		if c.sessionName != "tabby-dev" {
			t.Fatalf("expected session name to refresh, got %q", c.sessionName)
		}
		if c.sessionClients != 2 {
			t.Fatalf("expected 2 clients, got %d", c.sessionClients)
		}
		if c.windowCount != 6 {
			t.Fatalf("expected 6 windows, got %d", c.windowCount)
		}
	})

	t.Run("falls_back_to_cached_session_and_preserves_window_count", func(t *testing.T) {
		installFakeTmux(t, `
case "$*" in
  *'display-message -p #{session_name}'*) exit 0 ;;
  *'list-clients -t cached-session'*) printf '%s\n' 'client-a' ;;
  *'display-message -p #{session_windows}'*) printf '%s\n' '0' ;;
esac
exit 0
`)

		c := newTestCoordinator(t)
		c.sessionName = "cached-session"
		c.windowCount = 4

		c.RefreshSession()

		if c.sessionName != "cached-session" {
			t.Fatalf("expected cached session name to survive, got %q", c.sessionName)
		}
		if c.sessionClients != 1 {
			t.Fatalf("expected 1 client, got %d", c.sessionClients)
		}
		if c.windowCount != 4 {
			t.Fatalf("expected window count to remain unchanged, got %d", c.windowCount)
		}
	})
}

func TestSyncWindowNamesHonorsAutoRenameOff(t *testing.T) {
	installFakeTmux(t, `
case "$*" in
  *'show-option -gqv @tabby_auto_rename'*) printf '%s\n' 'off' ;;
esac
exit 0
`)

	c := newTestCoordinator(t)
	c.sessionID = "$1"
	c.windows = []tmux.Window{
		{
			ID:         "@1",
			Name:       "mywin",
			NameLocked: false,
			Panes: []tmux.Pane{
				{CurrentPath: "/tmp/project"},
			},
		},
	}

	pending := c.syncWindowNames()
	if len(pending) != 0 {
		t.Fatalf("expected no pending renames when auto rename is off, got %d", len(pending))
	}
	if got := c.windows[0].Name; got != "mywin" {
		t.Fatalf("expected window name to remain unchanged, got %q", got)
	}
}

func TestStripGroupedDisplayPrefix(t *testing.T) {
	if got := stripGroupedDisplayPrefix("Prismata|Infra", "Prismata"); got != "Infra" {
		t.Fatalf("expected stripped grouped display name, got %q", got)
	}
	if got := stripGroupedDisplayPrefix("Prismata Infra", "Prismata"); got != "Prismata Infra" {
		t.Fatalf("expected unmatched name to remain unchanged, got %q", got)
	}
	if got := stripGroupedDisplayPrefix("Prismata|", "Prismata"); got != "Prismata|" {
		t.Fatalf("expected empty suffix to preserve original name, got %q", got)
	}
}

func TestCreateNewWindowInCurrentGroupLegacyFallbackUsesSessionAndPathOverrides(t *testing.T) {
	logPath := installFakeTmux(t, `
case "$*" in
  *'display-message -p #{window_id}'*) printf '%s\n' '@1' ;;
  *'new-window -P -F #{window_id} -t sess-123:'*) printf '%s\n' '@2' ;;
esac
exit 0
`)

	tempHome := t.TempDir()
	t.Setenv("HOME", tempHome)

	c := newTestCoordinator(t)
	c.sessionID = "sess-123"
	c.grouped = []grouping.GroupedWindows{
		{
			Name: "Work",
			Windows: []tmux.Window{
				{ID: "@1", Index: 1},
			},
		},
	}
	c.config.Groups = []config.Group{
		{Name: "Work", Pattern: "^Work$", Theme: config.Theme{Bg: "#123456"}, WorkingDir: "~/projects/tabby"},
		{Name: "Default", Pattern: ".*", Theme: config.Theme{Bg: "#abcdef"}},
	}

	c.createNewWindowInCurrentGroup("client-ignored")

	time.Sleep(2200 * time.Millisecond)

	log := readFileString(t, logPath)
	wantPath := filepath.Join(tempHome, "projects", "tabby")
	checks := []string{
		"set-option -g @tabby_new_window_group Work",
		"set-option -g @tabby_new_window_path " + wantPath,
		"new-window -P -F #{window_id} -t sess-123: -c " + wantPath,
		"set-window-option -t @2 @tabby_group Work",
		"set-option -g @tabby_new_window_id @2",
		"select-window -t @2",
	}
	for _, want := range checks {
		if !strings.Contains(log, want) {
			t.Fatalf("expected fake tmux log to contain %q, got %q", want, log)
		}
	}
}
