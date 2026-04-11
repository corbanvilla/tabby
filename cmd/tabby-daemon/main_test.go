package main

import (
	"reflect"
	"testing"
)

func TestPaneTargetRegex(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		wantID string
	}{
		{
			name:   "single quoted",
			input:  "exec '/tmp/bin/pane-header' -session '$0' -window '@1' -pane '%12'",
			wantID: "%12",
		},
		{
			name:   "double quoted not matched",
			input:  "exec '/tmp/bin/pane-header' -session '$0' -window '@1' -pane \"%34\"",
			wantID: "",
		},
		{
			name:   "unquoted not matched",
			input:  "exec pane-header -session $0 -window @1 -pane %56",
			wantID: "",
		},
		{
			name:   "missing pane",
			input:  "exec pane-header -session $0 -window @1",
			wantID: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			matches := paneTargetRegex.FindStringSubmatch(tt.input)
			got := ""
			if len(matches) >= 2 {
				got = matches[1]
			}
			if got != tt.wantID {
				t.Fatalf("paneTargetRegex(%q) = %q, want %q", tt.input, got, tt.wantID)
			}
		})
	}
}

func TestParseSystemPaneSnapshot(t *testing.T) {
	raw := "@1\x1f%1\x1f0\x1fsidebar-renderer\x1fsidebar-renderer\n" +
		"@1\x1f%2\x1f1\x1fsidebar-renderer\x1fsidebar-renderer\n" +
		"@1\x1f%3\x1f0\x1fbash\x1f\n" +
		"@2\\037%4\\0370\\037sidebar\\037sidebar\n" +
		"@3\x1f%5\x1f0\x1fpane-header\x1fpane-header\n"

	got := parseSystemPaneSnapshot(raw)

	want := map[string]windowSystemPaneSnapshot{
		"@1": {
			liveSystemPanes: []string{"%1"},
			deadSystemPanes: []string{"%2"},
		},
		"@2": {
			liveSystemPanes: []string{"%4"},
		},
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parseSystemPaneSnapshot() = %#v, want %#v", got, want)
	}
}
