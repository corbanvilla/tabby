package main

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/brendandebeasi/tabby/pkg/colors"
	"github.com/brendandebeasi/tabby/pkg/config"
	"github.com/brendandebeasi/tabby/pkg/grouping"
	"github.com/brendandebeasi/tabby/pkg/tmux"
	zone "github.com/lrstanley/bubblezone"
)

var renderBenchOnce sync.Once

func benchmarkCoordinator() *Coordinator {
	renderBenchOnce.Do(func() { zone.NewGlobal() })

	cfg := testConfig()
	c := &Coordinator{
		config:             cfg,
		bgDetector:         colors.NewBackgroundDetector(colors.ThemeModeDark),
		windows:            []tmux.Window{},
		grouped:            []grouping.GroupedWindows{},
		windowVisualPos:    make(map[string]int),
		collapsedGroups:    make(map[string]bool),
		cwdColors:          make(map[string]CWDColorMapping),
		clientWidths:       make(map[string]int),
		prevPaneBusy:       make(map[string]bool),
		prevPaneTitle:      make(map[string]string),
		aiInputActive:      make(map[string]bool),
		hookPaneActive:     make(map[string]bool),
		hookPaneBusyIdleAt: make(map[string]int64),
		aiBellUntil:        make(map[string]int64),
		pendingMenus:       make(map[string][]menuItemDef),
		lastWindowSelect:   make(map[string]time.Time),
		lastWindowByClient: make(map[string]time.Time),
		lastPaneMenuOpen:   make(map[string]time.Time),
		sessionID:          "bench-session",
		globalWidth:        32,
	}

	windows := make([]tmux.Window, 0, 18)
	for i := 0; i < 18; i++ {
		groupName := "Default"
		switch {
		case i < 6:
			groupName = "Dev"
		case i < 12:
			groupName = "Ops"
		}

		win := tmux.Window{
			ID:        fmt.Sprintf("@bench-%d", i),
			Index:     i,
			Name:      fmt.Sprintf("window-%02d", i),
			Active:    i == 2,
			Last:      i == 1,
			Group:     groupName,
			SyncWidth: true,
			Busy:      i%5 == 0,
			Input:     i%7 == 0,
			Bell:      i%11 == 0,
			Activity:  i%4 == 0,
			Collapsed: i%6 == 0,
			Panes: []tmux.Pane{
				{
					ID:      fmt.Sprintf("%%%d-0", i),
					Index:   0,
					Command: "bash",
					Active:  true,
					Busy:    i%3 == 0,
				},
				{
					ID:      fmt.Sprintf("%%%d-1", i),
					Index:   1,
					Command: "nvim",
					Busy:    i%4 == 0,
				},
			},
		}
		if i%3 == 0 {
			win.Panes = append(win.Panes, tmux.Pane{
				ID:      fmt.Sprintf("%%%d-2", i),
				Index:   2,
				Command: "claude",
				AIBusy:  i%2 == 0,
				AIInput: i%2 == 1,
			})
		}
		windows = append(windows, win)
	}

	groups := []config.Group{
		testGroup("Dev", `^Dev\|`, "#3498db"),
		testGroup("Ops", `^Ops\|`, "#2ecc71"),
		{Name: "Default", Pattern: `.*`, Theme: config.Theme{Bg: "#2c3e50", Fg: "#ecf0f1"}},
	}

	c.stateMu.Lock()
	c.windows = windows
	c.grouped = grouping.GroupWindows(windows, groups)
	c.stateMu.Unlock()
	return c
}

func BenchmarkRenderForClientSidebar(b *testing.B) {
	c := benchmarkCoordinator()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = c.RenderForClient("@bench-2", 32, 48)
	}
}

func BenchmarkRenderForClientCollapsed(b *testing.B) {
	c := benchmarkCoordinator()
	c.sidebarCollapsed = true
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = c.RenderForClient("@bench-2", 1, 48)
	}
}
