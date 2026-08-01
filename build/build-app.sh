#!/bin/bash
#
# build-app.sh — Assemble "Shrink Design Zip.app".
#
# A SwiftUI window app: drop zone, live progress, and a save dialog. It bundles
# shrink-design-zip.sh and pngquant.py and shells out to them, so the optimizer
# logic lives in exactly one place.
#
# Building needs Swift (Xcode or the Command Line Tools). RUNNING the result
# does not: the binary links only /usr/lib/swift and /System/Library, both
# present on stock macOS 13+.
#
# Usage:  ./build/build-app.sh   (run from the repo root)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Shrink Design Zip"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
MIN_MACOS="13.0"

# Version stamped into the bundle. release.sh and CI pass the tag; a plain local
# build falls back to the newest tag, then to 0.0.0.
VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")"
fi
VERSION="${VERSION#v}"
# CFBundleVersion must be dot-separated digits, so strip any suffix such as
# "-beta.1". CFBundleShortVersionString keeps the full string.
BUILD_VERSION="$(printf '%s' "$VERSION" | sed -E 's/[^0-9.].*$//; s/\.+$//')"
[ -n "$BUILD_VERSION" ] || BUILD_VERSION="0.0.0"

for f in shrink-design-zip.sh build/pngquant.py app/main.swift; do
  [ -f "$ROOT/$f" ] || { echo "missing $f" >&2; exit 1; }
done
command -v swiftc >/dev/null || {
  echo "swiftc not found. Install Xcode or run: xcode-select --install" >&2; exit 1; }

mkdir -p "$DIST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# ---------------------------------------------------------------- binary ----
# Build for whichever architectures the toolchain supports so the app runs on
# both Apple Silicon and Intel.
ARCHS=()
BUILD_LOG="$DIST/.build.log"; : > "$BUILD_LOG"
for arch in arm64 x86_64; do
  if swiftc -O -parse-as-library -target "${arch}-apple-macos${MIN_MACOS}" \
       -o "$DIST/.bin-$arch" "$ROOT/app/main.swift" >>"$BUILD_LOG" 2>&1; then
    ARCHS+=("$DIST/.bin-$arch")
  fi
done
if [ ${#ARCHS[@]} -eq 0 ]; then
  # Show the compiler output rather than swallowing it; a silent "build failed"
  # is impossible to diagnose on a CI runner.
  echo "Swift build failed:" >&2
  cat "$BUILD_LOG" >&2
  exit 1
fi

if [ ${#ARCHS[@]} -gt 1 ]; then
  lipo -create "${ARCHS[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
  cp "${ARCHS[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"
rm -f "$DIST"/.bin-*

# --------------------------------------------------------------- payload ----
cp "$ROOT/shrink-design-zip.sh" "$APP/Contents/Resources/shrink-design-zip.sh"
cp "$ROOT/build/pngquant.py"    "$APP/Contents/Resources/pngquant.py"
chmod +x "$APP/Contents/Resources/shrink-design-zip.sh"

# ------------------------------------------------------------ Info.plist ----
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.kbrady1.shrinkdesignzip</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>app</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>ZIP archive</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.zip-archive</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# ------------------------------------------------------------------ icon ----
TMPD="$(mktemp -d)"; ICONSET="$TMPD/app.iconset"; mkdir -p "$ICONSET"
SVG="$TMPD/icon.svg"
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
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/app.icns" 2>/dev/null || true
rm -rf "$TMPD"

# --------------------------------------------------------------- signing ----
# Ad-hoc sign LAST. An app whose signature does not match its contents is
# refused outright ("plist or signature have been modified") rather than showing
# the ordinary "unidentified developer" prompt that right-click -> Open clears.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# Local test runs should not hit Gatekeeper. A copy sent to someone else is
# still quarantined on their machine; INSTALL.md covers that.
xattr -cr "$APP" 2>/dev/null || true

if codesign --verify --deep "$APP" 2>/dev/null; then
  echo "Signature: valid (ad-hoc)"
else
  echo "Signature: INVALID — the app will be refused rather than prompting" >&2
fi

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)"
echo "Built: $APP"
