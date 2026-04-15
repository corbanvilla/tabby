package version

import "testing"

func TestRelease(t *testing.T) {
	prev := Version
	defer func() { Version = prev }()

	Version = "v0.1.3-dirty"
	if got := Release(); got != "v0.1.3" {
		t.Fatalf("Release() = %q, want %q", got, "v0.1.3")
	}

	Version = "v0.2.0"
	if got := Release(); got != "v0.2.0" {
		t.Fatalf("Release() = %q, want %q", got, "v0.2.0")
	}

	Version = ""
	if got := Release(); got != "dev" {
		t.Fatalf("Release() empty = %q, want %q", got, "dev")
	}
}
