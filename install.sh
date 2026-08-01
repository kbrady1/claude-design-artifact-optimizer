#!/bin/bash
#
# install.sh — one-line installer for Shrink Design Zip.
#
#   curl -fsSL https://raw.githubusercontent.com/kbrady1/claude-design-artifact-optimizer/main/install.sh | bash
#
# Downloads the latest release, installs it to ~/Applications, and clears the
# quarantine flag so the app opens on the first double-click instead of showing
# the "unidentified developer" warning.

set -euo pipefail

REPO="kbrady1/claude-design-artifact-optimizer"
APP_NAME="Shrink Design Zip.app"
DEST="$HOME/Applications"
ASSET="ShrinkDesignZip.zip"

BLD=$'\033[1m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
say()  { printf "%s\n" "$*"; }
ok()   { printf "  ${GRN}✓${RST} %s\n" "$*"; }
warn() { printf "  ${YEL}!${RST} %s\n" "$*"; }
die()  { printf "${RED}error:${RST} %s\n" "$*" >&2; exit 1; }

printf "\n${BLD}Installing Shrink Design Zip${RST}\n\n"

[ "$(uname -s)" = "Darwin" ] || die "This app only runs on macOS."

# Refuse to run on a macOS older than the app supports, rather than installing
# something that cannot launch.
OSVER="$(sw_vers -productVersion 2>/dev/null || echo 0)"
if [ "${OSVER%%.*}" -lt 13 ] 2>/dev/null; then
  die "Needs macOS 13 or newer (found $OSVER)."
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Resolve the latest release. The API returns the tag and its assets; the
# browser_download_url is used so no token is needed on a public repo.
say "Finding the latest release…"
API="https://api.github.com/repos/$REPO/releases/latest"
JSON="$(curl -fsSL "$API" 2>/dev/null)" || die "Could not reach GitHub. Check your connection."

TAG="$(printf '%s' "$JSON" | /usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
URL="$(printf '%s' "$JSON" | /usr/bin/python3 -c \
  'import json,sys
d=json.load(sys.stdin)
print(next((a["browser_download_url"] for a in d.get("assets",[])
            if a["name"].endswith(".zip")), ""))' 2>/dev/null || true)"

[ -n "$URL" ] || die "No downloadable release found yet. Ask Kent to publish one."
ok "Found ${TAG:-latest}"

say "Downloading…"
curl -fsSL --progress-bar "$URL" -o "$TMP/$ASSET" || die "Download failed."
ok "Downloaded $(du -h "$TMP/$ASSET" | cut -f1)"

say "Installing…"
/usr/bin/ditto -x -k "$TMP/$ASSET" "$TMP/unpacked" 2>/dev/null \
  || die "Downloaded file was not a valid zip."

SRC="$(find "$TMP/unpacked" -maxdepth 2 -name '*.app' -print -quit)"
[ -n "$SRC" ] || die "No app found inside the download."

mkdir -p "$DEST"
# Replace any previous copy. Removing first avoids ditto merging a stale
# binary with new resources.
rm -rf "$DEST/$APP_NAME"
/usr/bin/ditto "$SRC" "$DEST/$APP_NAME" || die "Could not install to $DEST."

# The app is ad-hoc signed, not notarized. Clearing quarantine here means the
# designer never sees the "unidentified developer" dialog — the user ran this
# installer deliberately, which is the same trust decision.
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

if codesign --verify --deep "$DEST/$APP_NAME" 2>/dev/null; then
  ok "Installed to ~/Applications"
else
  warn "Installed, but the signature could not be verified."
fi

printf "\n${BLD}Done.${RST} ${DIM}Opening it now…${RST}\n\n"
say "  Drag a design .zip into the window to shrink it."
say "  Find it later in ${BLD}~/Applications${RST} or via Spotlight."
printf "\n"

open "$DEST/$APP_NAME" 2>/dev/null || true
