#!/bin/bash
#
# build-app.sh — Assemble "Shrink Design Zip.app".
#
# Produces a normal double-clickable / drag-and-drop Mac app that bundles
# shrink-design-zip.sh and pngquant.py. The app needs nothing installed: it
# uses only sips, zip, and the system python3.
#
# Usage:  ./build/build-app.sh   (run from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Shrink Design Zip"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

[ -f "$ROOT/shrink-design-zip.sh" ] || { echo "missing shrink-design-zip.sh" >&2; exit 1; }
[ -f "$ROOT/build/pngquant.py" ]    || { echo "missing build/pngquant.py" >&2; exit 1; }

mkdir -p "$DIST"
rm -rf "$APP"

# osacompile builds a real AppleScript droplet: it wires up the executable, the
# Apple-event plumbing, and the "on open" drop handler. Hand-assembling those
# does not produce a working drop target.
osacompile -o "$APP" "$ROOT/build/driver.applescript"

# ------------------------------------------------------------- payload ------
cp "$ROOT/shrink-design-zip.sh" "$APP/Contents/Resources/shrink-design-zip.sh"
cp "$ROOT/build/pngquant.py"    "$APP/Contents/Resources/pngquant.py"
chmod +x "$APP/Contents/Resources/shrink-design-zip.sh"

# ------------------------------------------------------------ Info.plist ----
# Patch the plist osacompile generated: give the app a real name and identifier,
# and declare that it accepts dropped .zip files.
PL="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PL" >/dev/null 2>&1 || true; }

# osacompile names the executable "droplet", which is what shows in the menu bar
# and in Force Quit. Rename it so the user sees the app's real name.
if [ -f "$APP/Contents/MacOS/droplet" ]; then
  mv "$APP/Contents/MacOS/droplet" "$APP/Contents/MacOS/$APP_NAME"
  pb "Set :CFBundleExecutable $APP_NAME"
fi
pb "Set :CFBundleName $APP_NAME"
pb "Add :CFBundleDisplayName string $APP_NAME"
pb "Set :CFBundleIdentifier com.neighbor.shrinkdesignzip"
pb "Set :CFBundleShortVersionString 1.0"
pb "Add :NSHighResolutionCapable bool true"
pb "Delete :CFBundleDocumentTypes"
pb "Add :CFBundleDocumentTypes array"
pb "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'ZIP archive'"
pb "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer"
pb "Add :CFBundleDocumentTypes:0:LSItemContentTypes array"
pb "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.zip-archive"

# ------------------------------------------------------------- icon ---------
# Generate a simple icon so the app does not show the generic blank page.
ICONSET="$(mktemp -d)/app.iconset"; mkdir -p "$ICONSET"
SVG="$(mktemp).svg"
cat > "$SVG" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="#4F8EF7"/><stop offset="100%" stop-color="#2B5FD9"/>
  </linearGradient></defs>
  <rect width="1024" height="1024" rx="228" fill="url(#g)"/>
  <g fill="#fff">
    <rect x="300" y="200" width="424" height="150" rx="28" opacity="0.95"/>
    <rect x="360" y="430" width="304" height="110" rx="24" opacity="0.75"/>
    <rect x="420" y="620" width="184" height="80" rx="20" opacity="0.55"/>
    <path d="M512 780 l90 100 h-60 v60 h-60 v-60 h-60 z"/>
  </g>
</svg>
SVGEOF
for s in 16 32 128 256 512; do
  sips -s format png "$SVG" --out "$ICONSET/icon_${s}x${s}.png" -Z $s >/dev/null 2>&1 || true
  sips -s format png "$SVG" --out "$ICONSET/icon_${s}x${s}@2x.png" -Z $((s*2)) >/dev/null 2>&1 || true
done
# osacompile names its icon applet.icns; overwrite that so the app picks it up.
if iconutil -c icns "$ICONSET" -o "$ICONSET/../app.icns" 2>/dev/null; then
  cp "$ICONSET/../app.icns" "$APP/Contents/Resources/applet.icns" 2>/dev/null || true
  cp "$ICONSET/../app.icns" "$APP/Contents/Resources/droplet.icns" 2>/dev/null || true
fi

# Editing Info.plist and renaming the executable invalidates the ad-hoc
# signature osacompile applied. An app with a BROKEN signature is refused
# outright ("plist or signature have been modified") instead of showing the
# ordinary "unidentified developer" prompt that a right-click -> Open clears,
# so re-sign after every modification. Signing must come last.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# Strip the quarantine flag on the freshly built copy so a local test run does
# not hit Gatekeeper. A copy sent to someone else is still quarantined on their
# machine; INSTALL.md covers the one-time right-click -> Open step.
xattr -cr "$APP" 2>/dev/null || true

if codesign --verify --deep "$APP" 2>/dev/null; then
  echo "Signature: valid (ad-hoc)"
else
  echo "Signature: INVALID — the app will be refused rather than prompting" >&2
fi

echo "Built: $APP"
