#!/usr/bin/env bash
set -euo pipefail

REMOTE="${REMOTE:-origin}"
VERSION="${1:-}"

usage() {
	cat <<'EOF'
Usage: scripts/release.sh [vX.Y.Z]

Builds stamped binaries, creates an annotated release tag, and pushes the
current branch plus the tag. If no version is provided, the latest local
vX.Y.Z tag is bumped by one patch version.

Environment:
  REMOTE=origin        Git remote to push branch and tag to.
  SKIP_TESTS=1         Skip the release helper's test run.

Examples:
  scripts/release.sh v0.1.10
  REMOTE=upstream scripts/release.sh
EOF
}

if [ "${VERSION:-}" = "-h" ] || [ "${VERSION:-}" = "--help" ]; then
	usage
	exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
cd "$repo_root"

git fetch --tags --quiet "$REMOTE"

latest_patch_tag() {
	git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true
}

bump_patch() {
	local latest major minor patch
	latest="$(latest_patch_tag)"
	if [ -z "$latest" ]; then
		printf "v0.1.0\n"
		return
	fi
	major="${latest#v}"
	major="${major%%.*}"
	minor="${latest#v${major}.}"
	minor="${minor%%.*}"
	patch="${latest##*.}"
	printf "v%s.%s.%s\n" "$major" "$minor" "$((patch + 1))"
}

if [ -z "$VERSION" ]; then
	VERSION="$(bump_patch)"
fi

if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
	echo "Invalid release version: $VERSION" >&2
	echo "Expected a tag like v0.1.10" >&2
	exit 1
fi

branch="$(git branch --show-current)"
if [ -z "$branch" ]; then
	echo "Cannot release from a detached HEAD." >&2
	exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "Worktree has uncommitted changes. Commit them before releasing." >&2
	git status --short >&2
	exit 1
fi

if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
	echo "Tag already exists locally: $VERSION" >&2
	exit 1
fi

remote_tag="$(git ls-remote --tags "$REMOTE" "refs/tags/$VERSION")"
if [ -n "$remote_tag" ]; then
	echo "Tag already exists on $REMOTE: $VERSION" >&2
	exit 1
fi

echo "Building stamped binaries for $VERSION..."
VERSION="$VERSION" ./scripts/install.sh >/dev/null

metadata="$(go version -m ./bin/tabby-daemon 2>/dev/null || true)"
if ! grep -Fq "github.com/brendandebeasi/tabby/pkg/version.Version=$VERSION" <<<"$metadata"; then
	echo "Built tabby-daemon is missing the expected version ldflag." >&2
	echo "$metadata" >&2
	exit 1
fi

if [ "${SKIP_TESTS:-0}" != "1" ]; then
	echo "Running release checks..."
	env -u TABBY_RUNTIME_PREFIX go test ./pkg/version ./pkg/daemon
fi

git tag -a "$VERSION" -m "Release $VERSION"
git push "$REMOTE" "$branch"
git push "$REMOTE" "$VERSION"

echo "Pushed $VERSION to $REMOTE. GitHub Actions will build and publish the release assets."
