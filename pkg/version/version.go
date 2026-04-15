package version

import "strings"

// Version is injected at build time. It falls back to "dev" for test runs and
// local builds without ldflags.
var Version = "dev"

// Release returns the user-facing release string. For git-describe values such
// as "v0.1.3-dirty", it trims the suffix so the UI shows the release version.
func Release() string {
	v := strings.TrimSpace(Version)
	if v == "" {
		return "dev"
	}
	if idx := strings.IndexRune(v, '-'); idx > 0 {
		return v[:idx]
	}
	return v
}
