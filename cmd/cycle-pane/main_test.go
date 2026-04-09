package main

import "testing"

func TestComputeDimBGTransparentDisablesPaneFill(t *testing.T) {
	if got := computeDimBG("transparent", 0.72); got != "" {
		t.Fatalf("expected no dim background for transparent terminal bg, got %q", got)
	}
}
