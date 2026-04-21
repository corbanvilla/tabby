#!/usr/bin/env bash
set -euo pipefail

echo "=== Integration Test: Release Tooling ==="

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd -P)"
cd "$PROJECT_ROOT"

bash -n scripts/install.sh
bash -n scripts/release.sh

VERSION=v9.8.7-test ./scripts/install.sh >/tmp/tabby-release-tooling-install.log

if go version -m bin/tabby-daemon | grep -Fq 'github.com/brendandebeasi/tabby/pkg/version.Version=v9.8.7-test'; then
	echo "✓ install.sh stamps tabby-daemon with VERSION"
else
	echo "✗ install.sh did not stamp tabby-daemon with VERSION"
	go version -m bin/tabby-daemon || true
	exit 1
fi

if grep -Fq 'GITHUB_REF_TYPE' scripts/install.sh && grep -Fq 'GITHUB_REF_NAME' scripts/install.sh; then
	echo "✓ install.sh reads GitHub tag env when VERSION is unset"
else
	echo "✗ install.sh does not read GitHub tag env for release builds"
	exit 1
fi

if grep -Fq 'env -u TABBY_RUNTIME_PREFIX go test' scripts/release.sh; then
	echo "✓ release helper runs checks without runtime path isolation env"
else
	echo "✗ release helper may inherit TABBY_RUNTIME_PREFIX during tests"
	exit 1
fi

echo "=== Release tooling test passed ==="
