#!/bin/bash
#
# release.sh — build, package, and publish a GitHub release.
#
#   ./build/release.sh v2.0.1
#   ./build/release.sh v2.0.1 --notes "Fixed the progress bar"
#
# Builds a fresh app, zips it with ditto (which preserves the bundle's
# signature and resource forks — a plain `zip` can corrupt an .app), then
# creates the release and uploads the asset.
#
# install.sh always fetches /releases/latest, so publishing is all that is
# needed for users to get the new version.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="kbrady1/claude-design-artifact-optimizer"
APP_NAME="Shrink Design Zip"
ASSET="ShrinkDesignZip.zip"

BLD=$'\033[1m'; GRN=$'\033[32m'; RED=$'\033[31m'; RST=$'\033[0m'
ok()  { printf "  ${GRN}✓${RST} %s\n" "$*"; }
die() { printf "${RED}error:${RST} %s\n" "$*" >&2; exit 1; }

TAG="${1:-}"
[ -n "$TAG" ] || die "usage: $(basename "$0") <tag> [--notes \"...\"]"
case "$TAG" in v*) ;; *) die "tag should start with 'v' (e.g. v2.0.1)" ;; esac
shift

NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v gh >/dev/null || die "gh CLI not found. brew install gh"
gh auth status >/dev/null 2>&1 || die "Not logged in. Run: gh auth login"

# Refuse to publish a release from a dirty tree: the tag would not match what
# was actually built.
[ -z "$(git -C "$ROOT" status --porcelain)" ] || \
  die "Working tree is dirty. Commit or stash first."

gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && \
  die "Release $TAG already exists. Pick a new tag or delete it first."

printf "\n${BLD}Releasing %s${RST}\n\n" "$TAG"

printf "Building…\n"
VERSION="$TAG" "$ROOT/build/build-app.sh" >/dev/null 2>&1 || die "Build failed. Run ./build/build-app.sh to see why."
APP="$ROOT/dist/$APP_NAME.app"
[ -d "$APP" ] || die "Build produced no app."
codesign --verify --deep "$APP" 2>/dev/null || die "Built app has an invalid signature."
ok "Built $(lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo "")"

printf "Packaging…\n"
rm -f "$ROOT/dist/$ASSET"
# ditto --sequesterRsrc keeps the signature intact; `zip -r` does not.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/$ASSET" \
  || die "Packaging failed."
ok "Packaged $(du -h "$ROOT/dist/$ASSET" | cut -f1)"

# Verify the archive actually round-trips before publishing it, so a corrupt
# asset never reaches a user.
VTMP="$(mktemp -d)"; trap 'rm -rf "$VTMP"' EXIT
/usr/bin/ditto -x -k "$ROOT/dist/$ASSET" "$VTMP" 2>/dev/null || die "Archive does not unpack."
VAPP="$(find "$VTMP" -maxdepth 2 -name '*.app' -print -quit)"
[ -n "$VAPP" ] || die "Archive contains no .app."
codesign --verify --deep "$VAPP" 2>/dev/null || die "Unpacked app fails signature check."
ok "Verified round-trip"

printf "Publishing…\n"
[ -n "$NOTES" ] || NOTES="Shrinks Claude Design export ZIPs for upload."
gh release create "$TAG" "$ROOT/dist/$ASSET" \
  --repo "$REPO" --title "$TAG" --notes "$NOTES" >/dev/null || die "Release failed."
ok "Published"

printf "\n${BLD}Done.${RST} Install with:\n\n"
printf "  curl -fsSL https://raw.githubusercontent.com/%s/main/install.sh | bash\n\n" "$REPO"
