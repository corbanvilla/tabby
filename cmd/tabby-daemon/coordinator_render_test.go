package main

import (
	"strings"
	"sync"
	"testing"

	"github.com/brendandebeasi/tabby/pkg/colors"
	"github.com/brendandebeasi/tabby/pkg/config"
	"github.com/brendandebeasi/tabby/pkg/grouping"
	"github.com/brendandebeasi/tabby/pkg/tmux"
	"github.com/brendandebeasi/tabby/pkg/version"
	zone "github.com/lrstanley/bubblezone"
	"github.com/stretchr/testify/assert"
)

var renderTestOnce sync.Once

func newRenderCoordinator(t *testing.T) *Coordinator {
	t.Helper()
	renderTestOnce.Do(func() { zone.NewGlobal() })
	c := newTestCoordinator(t)
	c.bgDetector = colors.NewBackgroundDetector(colors.ThemeModeAuto)
	return c
}

func TestRenderForClient_CollapsedSidebar(t *testing.T) {
	c := newRenderCoordinator(t)
	c.sidebarCollapsed = true
	payload := c.RenderForClient("test-client", 1, 24)
	assert.NotNil(t, payload)
	assert.Equal(t, 1, payload.Width)
	assert.Equal(t, 24, payload.Height)
	assert.NotEmpty(t, payload.Regions)
}

func TestRenderForClient_CollapsedSidebarZeroWidth(t *testing.T) {
	c := newRenderCoordinator(t)
	c.sidebarCollapsed = true
	payload := c.RenderForClient("test-client", 0, 10)
	assert.NotNil(t, payload)
	assert.GreaterOrEqual(t, payload.Width, 1)
}

func TestRenderForClient_EmptyWindowsAndGroups(t *testing.T) {
	c := newRenderCoordinator(t)
	payload := c.RenderForClient("test-client", 30, 24)
	assert.NotNil(t, payload)
	assert.Equal(t, 30, payload.Width)
}

func TestRenderForClient_SmallHeight(t *testing.T) {
	c := newRenderCoordinator(t)
	payload := c.RenderForClient("test-client", 30, 3)
	assert.NotNil(t, payload)
}

func TestRenderForClient_SmallWidth(t *testing.T) {
	c := newRenderCoordinator(t)
	payload := c.RenderForClient("test-client", 2, 24)
	assert.NotNil(t, payload)
	assert.GreaterOrEqual(t, payload.Width, 10)
}

func TestRenderForClient_WithWindows(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{
		testWindow("bash", true, "bash"),
		testWindow("vim", false, "vim"),
	}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1", ActiveBg: "#3498db", ActiveFg: "#ffffff"},
		Windows: c.windows,
	}}
	c.stateMu.Unlock()
	payload := c.RenderForClient("test-client", 30, 24)
	assert.NotNil(t, payload)
	assert.NotEmpty(t, payload.Content)
}

func TestRenderForClient_ContentContainsWindowNames(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{testWindow("mywindow", true, "bash")}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1"},
		Windows: c.windows,
	}}
	c.stateMu.Unlock()
	payload := c.RenderForClient("test-client", 30, 24)
	assert.NotNil(t, payload)
	assert.Contains(t, payload.Content, "mywindow")
}

func TestRenderHeaderForClient_EmptyClientID(t *testing.T) {
	c := newRenderCoordinator(t)
	payload := c.RenderHeaderForClient("", 80, 1)
	assert.Nil(t, payload)
}

func TestRenderHeaderForClient_NonHeaderClientID(t *testing.T) {
	c := newRenderCoordinator(t)
	payload := c.RenderHeaderForClient("renderer:@1", 80, 1)
	assert.NotNil(t, payload)
}

func TestRenderHeaderForClient_PaneNotFound(t *testing.T) {
	c := newRenderCoordinator(t)
	payload := c.RenderHeaderForClient("header:%99", 80, 1)
	assert.NotNil(t, payload)
	assert.Equal(t, strings.Repeat(" ", 80), payload.Content)
}

func TestRenderHeaderForClient_PaneFound(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{{
		ID:    "@1",
		Index: 1,
		Name:  "testwin",
		Panes: []tmux.Pane{
			{ID: "%1", Command: "bash", Active: true},
		},
	}}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1", ActiveBg: "#3498db"},
		Windows: c.windows,
	}}
	c.stateMu.Unlock()
	payload := c.RenderHeaderForClient("header:%1", 80, 1)
	assert.NotNil(t, payload)
	assert.Equal(t, 80, payload.Width)
}

func TestRenderHeaderForClient_SmallWidth(t *testing.T) {
	c := newRenderCoordinator(t)
	payload := c.RenderHeaderForClient("header:%1", 2, 1)
	assert.NotNil(t, payload)
	assert.GreaterOrEqual(t, payload.Width, 5)
}

func TestGenerateSidebarHeader_EmptyConfig(t *testing.T) {
	c := newRenderCoordinator(t)
	content, regions := c.generateSidebarHeader(30, "test-client")
	assert.NotEmpty(t, content)
	_ = regions
}

func TestGenerateSidebarHeader_WithTitle(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Sidebar.Header.Text = "MY SIDEBAR"
	content, _ := c.generateSidebarHeader(30, "test-client")
	assert.Contains(t, content, "MY SIDEBAR")
}

func TestGenerateSidebarHeader_DoesNotShowReleaseVersion(t *testing.T) {
	prev := version.Version
	version.Version = "v9.9.9-dirty"
	defer func() { version.Version = prev }()

	c := newRenderCoordinator(t)
	content, _ := c.generateSidebarHeader(30, "test-client")
	assert.NotContains(t, content, "v9.9.9")
	assert.NotContains(t, content, "v9.9.9-dirty")
}

func TestGenerateSidebarHeader_WithActiveWindow(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{{
		ID:     "@1",
		Active: true,
		Group:  "Default",
	}}
	c.stateMu.Unlock()
	content, _ := c.generateSidebarHeader(30, "test-client")
	assert.NotEmpty(t, content)
}

func TestGenerateMainContent_EmptyGrouped(t *testing.T) {
	c := newRenderCoordinator(t)
	content, regions := c.generateMainContent("test-client", 30, 24)
	_ = content
	_ = regions
}

func TestGenerateMainContent_WithWindows(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{
		testWindow("win1", true, "bash"),
		testWindow("win2", false, "vim"),
	}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1", ActiveBg: "#3498db", ActiveFg: "#ffffff"},
		Windows: c.windows,
	}}
	c.stateMu.Unlock()
	content, regions := c.generateMainContent("test-client", 30, 24)
	assert.NotEmpty(t, content)
	assert.NotEmpty(t, regions)
}

func TestGetSidebarActiveLabelFg_DefaultsToBlack(t *testing.T) {
	c := newRenderCoordinator(t)
	assert.Equal(t, "#000000", c.getSidebarActiveLabelFg())
}

func TestGetSidebarActiveLabelFg_ConfigWins(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Sidebar.Colors.ActiveFg = "#112233"
	assert.Equal(t, "#112233", c.getSidebarActiveLabelFg())
}

func TestGenerateMainContent_ActiveWindowMatchesClient(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{testWindow("active-win", true, "bash")}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1"},
		Windows: c.windows,
	}}
	c.stateMu.Unlock()
	content, _ := c.generateMainContent("@active-win", 30, 24)
	assert.Contains(t, content, "active-win")
}

func TestGenerateMainContent_WithPanes(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{{
		ID:     "@1",
		Name:   "multiPane",
		Active: true,
		Panes: []tmux.Pane{
			{ID: "%1", Command: "bash", Active: true, Width: 80, Height: 12, Top: 0},
			{ID: "%2", Command: "vim", Active: false, Width: 80, Height: 12, Top: 12},
		},
	}}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1"},
		Windows: c.windows,
	}}
	c.stateMu.Unlock()
	content, _ := c.generateMainContent("test-client", 30, 24)
	assert.NotEmpty(t, content)
}

func TestGenerateMainContent_RendersPaneBellForExpandedMultiPaneWindow(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Indicators.Bell.Enabled = true
	c.config.Indicators.Bell.Icon = "BELL"
	c.stateMu.Lock()
	c.windows = []tmux.Window{{
		ID:     "@1",
		Index:  0,
		Name:   "main",
		Active: true,
		Panes: []tmux.Pane{
			{ID: "%1", Command: "bash", LockedTitle: "left-ai", AIBell: true, Width: 80, Height: 12, Top: 0, Left: 0},
			{ID: "%2", Command: "bash", LockedTitle: "right-ai", Width: 80, Height: 12, Top: 0, Left: 81},
		},
	}}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1"},
		Windows: c.windows,
	}}
	c.windowVisualPos = map[string]int{"@1": 0}
	c.stateMu.Unlock()

	content, _ := c.generateMainContent("@1", 40, 24)
	assert.Contains(t, content, "left-ai")
	assert.Contains(t, content, "right-ai")
	assert.Contains(t, content, "BELL")
}

func TestGenerateMainContent_RendersBellForActiveSinglePaneWindow(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Indicators.Bell.Enabled = true
	c.config.Indicators.Bell.Icon = "BELL"
	c.stateMu.Lock()
	c.windows = []tmux.Window{{
		ID:     "@1",
		Index:  0,
		Name:   "main",
		Active: true,
		Bell:   true,
		Panes: []tmux.Pane{
			{ID: "%1", Command: "codex", Active: true, AIBell: true, Width: 80, Height: 24, Top: 0, Left: 0},
		},
	}}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1"},
		Windows: c.windows,
	}}
	c.windowVisualPos = map[string]int{"@1": 0}
	c.stateMu.Unlock()

	content, _ := c.generateMainContent("@1", 40, 24)
	assert.Contains(t, content, "BELL")
	assert.Contains(t, content, "main")
}

func TestRenderClockWidget(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Clock.Enabled = true
	result := c.renderClockWidget(30)
	assert.NotEmpty(t, result)
}

func TestRenderClockWidget_CustomFormat(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Clock.Enabled = true
	c.config.Widgets.Clock.Format = "15:04"
	result := c.renderClockWidget(30)
	assert.NotEmpty(t, result)
}

func TestRenderClockWidget_ShowsReleaseBelowDate(t *testing.T) {
	prev := version.Version
	version.Version = "v9.9.9-dirty"
	defer func() { version.Version = prev }()

	c := newRenderCoordinator(t)
	c.config.Widgets.Clock.Enabled = true
	c.config.Widgets.Clock.ShowDate = true
	result := c.renderClockWidget(30)
	assert.Contains(t, result, "v9.9.9")
	assert.NotContains(t, result, "v9.9.9-dirty")
}

func TestRenderGitWidget_NotARepo(t *testing.T) {
	c := newRenderCoordinator(t)
	c.isGitRepo = false
	result := c.renderGitWidget(30)
	_ = result
}

func TestRenderGitWidget_IsRepo(t *testing.T) {
	c := newRenderCoordinator(t)
	c.isGitRepo = true
	c.gitBranch = "main"
	c.gitDirty = 3
	result := c.renderGitWidget(30)
	assert.NotEmpty(t, result)
}

func TestRenderSessionWidget(t *testing.T) {
	c := newRenderCoordinator(t)
	c.sessionName = "my-session"
	c.sessionClients = 2
	c.windowCount = 5
	result := c.renderSessionWidget(30)
	_ = result
}

func TestRenderPetWidget_Disabled(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Pet.Enabled = false
	result := c.renderPetWidget(30)
	assert.Empty(t, result)
}

func TestRenderPetWidget_Enabled(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Pet.Enabled = true
	c.lastWidth = 30
	result := c.renderPetWidget(30)
	_ = result
}

func TestRenderWidgetZone_EmptyEntries(t *testing.T) {
	c := newRenderCoordinator(t)
	content, regions := c.renderWidgetZone(nil, 30)
	assert.Empty(t, content)
	assert.Empty(t, regions)
}

func TestRenderWidgetZone_WithEntry(t *testing.T) {
	c := newRenderCoordinator(t)
	entries := []widgetEntry{{
		name:    "clock",
		zone:    "bottom",
		content: "12:00:00",
	}}
	content, _ := c.renderWidgetZone(entries, 30)
	assert.Contains(t, content, "12:00:00")
}

func TestGenerateWidgetZones_NoWidgets(t *testing.T) {
	c := newRenderCoordinator(t)
	top, topR, bottom, bottomR := c.generateWidgetZones(30, false)
	assert.Empty(t, top)
	assert.Empty(t, topR)
	assert.NotEmpty(t, bottom)
	_ = bottomR
}

func TestRenderSidebarResizeButtons(t *testing.T) {
	c := newRenderCoordinator(t)
	result := c.renderSidebarResizeButtons(30)
	assert.NotEmpty(t, result)
}

func TestRenderPinnedActionButtons_NarrowWidth(t *testing.T) {
	c := newRenderCoordinator(t)
	result := c.renderPinnedActionButtons(5)
	_ = result
}

func TestRenderPinnedActionButtons_WideWidth(t *testing.T) {
	c := newRenderCoordinator(t)
	result := c.renderPinnedActionButtons(40)
	_ = result
}

func TestRenderClaudeWidget_Disabled(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Claude.Enabled = false
	result := c.renderClaudeWidget(30)
	assert.Empty(t, result)
}

func TestRenderClaudeWidget_Enabled(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Claude.Enabled = true
	result := c.renderClaudeWidget(30)
	assert.NotEmpty(t, result)
}

func TestRenderClaudeWidget_EnabledWithDivider(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Claude.Enabled = true
	c.config.Widgets.Claude.Divider = "─"
	result := c.renderClaudeWidget(30)
	assert.NotEmpty(t, result)
}

func TestGetHeaderColorsForPane_PaneNotFound(t *testing.T) {
	c := newRenderCoordinator(t)
	colors := c.GetHeaderColorsForPane("%99")
	assert.NotEmpty(t, colors.Fg+colors.Bg)
}

func TestGetHeaderColorsForPane_PaneFound(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{{
		ID: "@1", Index: 1, Active: true,
		Panes: []tmux.Pane{{ID: "%1", Command: "bash"}},
	}}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1", ActiveBg: "#3498db", ActiveFg: "#ffffff"},
		Windows: c.windows,
	}}
	c.stateMu.Unlock()
	colors := c.GetHeaderColorsForPane("%1")
	assert.NotEmpty(t, colors.Fg+colors.Bg)
}

func TestRenderForClient_WithCollapsedWindow(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{{
		ID: "@1", Index: 1, Active: true, Collapsed: true,
		Panes: []tmux.Pane{
			{ID: "%1", Command: "bash", Active: true},
			{ID: "%2", Command: "vim"},
		},
	}}
	c.grouped = []grouping.GroupedWindows{{
		Name:    "Default",
		Theme:   config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1"},
		Windows: c.windows,
	}}
	c.stateMu.Unlock()
	payload := c.RenderForClient("test-client", 30, 24)
	assert.NotNil(t, payload)
}

func TestRenderSessionWidget_Enabled(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Session.Enabled = true
	c.sessionName = "work"
	c.windowCount = 3
	c.sessionClients = 1
	result := c.renderSessionWidget(30)
	assert.NotEmpty(t, result)
}

func TestRenderSessionWidget_Disabled(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Session.Enabled = false
	result := c.renderSessionWidget(30)
	assert.Empty(t, result)
}

func TestRenderClockWidget_AlwaysRendersContent(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Clock.Enabled = false
	result := c.renderClockWidget(30)
	assert.NotEmpty(t, result)
}

func TestRenderGitWidget_DirtyRepo(t *testing.T) {
	c := newRenderCoordinator(t)
	c.isGitRepo = true
	c.gitBranch = "feature/my-branch"
	c.gitDirty = 5
	c.gitAhead = 2
	result := c.renderGitWidget(30)
	assert.NotEmpty(t, result)
}

func TestCollectWidgetEntries_WithClockEnabled(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Clock.Enabled = true
	entries := c.collectWidgetEntries(30, false)
	found := false
	for _, e := range entries {
		if e.name == "clock" {
			found = true
			break
		}
	}
	assert.True(t, found)
}

func TestCollectWidgetEntries_WithSessionEnabled(t *testing.T) {
	c := newRenderCoordinator(t)
	c.config.Widgets.Session.Enabled = true
	entries := c.collectWidgetEntries(30, false)
	found := false
	for _, e := range entries {
		if e.name == "session" {
			found = true
			break
		}
	}
	assert.True(t, found)
}

func TestRenderForClient_MultipleGroups(t *testing.T) {
	c := newRenderCoordinator(t)
	c.stateMu.Lock()
	c.windows = []tmux.Window{
		testWindow("group1-win", true, "bash"),
		testWindow("group2-win", false, "vim"),
	}
	c.grouped = []grouping.GroupedWindows{
		{
			Name:    "Group1",
			Theme:   config.Theme{Bg: "#3498db", Fg: "#ffffff"},
			Windows: []tmux.Window{c.windows[0]},
		},
		{
			Name:    "Group2",
			Theme:   config.Theme{Bg: "#e74c3c", Fg: "#ffffff"},
			Windows: []tmux.Window{c.windows[1]},
		},
	}
	c.stateMu.Unlock()
	payload := c.RenderForClient("test-client", 30, 24)
	assert.NotNil(t, payload)
	assert.Contains(t, payload.Content, "group1-win")
	assert.Contains(t, payload.Content, "group2-win")
}
