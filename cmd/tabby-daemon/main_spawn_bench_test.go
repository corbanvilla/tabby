package main

import (
	"fmt"
	"strings"
	"testing"
)

func buildSyntheticPaneSnapshot(windowCount, panesPerWindow int) string {
	var b strings.Builder
	paneID := 1
	for w := 0; w < windowCount; w++ {
		wid := fmt.Sprintf("@%d", w)
		for p := 0; p < panesPerWindow; p++ {
			cmd := "bash"
			start := ""
			dead := "0"
			if p == 0 {
				cmd = "sidebar-renderer"
				start = "sidebar-renderer"
			}
			if p == panesPerWindow-1 && p > 0 {
				cmd = "sidebar-renderer"
				start = "sidebar-renderer"
				dead = "1"
			}
			fmt.Fprintf(&b, "%s\x1f%%%d\x1f%s\x1f%s\x1f%s\n", wid, paneID, dead, cmd, start)
			paneID++
		}
	}
	return b.String()
}

func BenchmarkParseSystemPaneSnapshot_20x6(b *testing.B) {
	raw := buildSyntheticPaneSnapshot(20, 6)
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = parseSystemPaneSnapshot(raw)
	}
}

func BenchmarkParseSystemPaneSnapshot_50x8(b *testing.B) {
	raw := buildSyntheticPaneSnapshot(50, 8)
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = parseSystemPaneSnapshot(raw)
	}
}
