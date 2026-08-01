# claude-design-artifact-optimizer

Shrinks Claude Design export ZIPs so they can be uploaded. A 778 MB export
becomes about 23 MB — roughly 97% smaller — with no visible quality loss.

Ships as a Mac app with a drop zone, live progress, and a save dialog — and as
a CLI. Running it needs nothing installed: only `sips`, `zip`, and the system
`python3`. (Building the app needs Swift; running it does not.)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/kbrady1/claude-design-artifact-optimizer/main/install.sh | bash
```

Installs to `~/Applications` and opens it. Re-run to update. See
**[INSTALL.md](INSTALL.md)** for the designer-facing walkthrough.

## For engineers

```bash
./shrink-design-zip.sh "Topic page.zip"        # defaults to a 25 MB target
./shrink-design-zip.sh "Topic page.zip" 10     # custom target, in MB
```

Writes `<name>-optimized.zip` next to the input. The original is never
modified.

Exit codes: `0` success, `2` target not reached, `3` a reference did not
resolve.

### Build the app

```bash
./build/build-app.sh      # writes dist/Shrink Design Zip.app
```

### Cut a release

```bash
./build/release.sh v2.0.1
```

Builds, packages with `ditto` (a plain `zip` corrupts a signed `.app`),
verifies the archive round-trips and still passes `codesign`, then publishes.
`install.sh` always fetches `/releases/latest`, so publishing is the only step
needed for users to get the new version.

## How it works

Three passes, cheapest first, stopping as soon as the target is met:

1. **Remove orphans** — images that no file references. Exports bundle the
   entire upload history, not just what the design uses. This is usually most
   of the savings.
2. **Remove duplicates** — byte-identical copies, with references repointed to
   the surviving file by full resolved path.
3. **Shrink images** — resize and recompress, escalating through quality tiers
   (2000px/q82 → 1600/q75 → 1200/q65 → 1000/q55) only as far as needed.

Afterward it re-scans every reference and reports any that no longer resolve,
distinguishing breakage it caused from breakage already present in the export.

### Files

| Path | Purpose |
|---|---|
| `shrink-design-zip.sh` | The optimizer. Runs standalone. |
| `build/pngquant.py` | PNG palette quantizer (see below). |
| `app/main.swift` | SwiftUI window: drop zone, progress, save dialog. |
| `build/build-app.sh` | Compiles the app and assembles the bundle. |
| `build/release.sh` | Builds, verifies, and publishes a GitHub release. |
| `install.sh` | What the curl one-liner runs. |

### Progress protocol

The UI does not parse terminal output. Setting `PROGRESS=<file>` makes the
script append one event per line, which the app polls four times a second:

```
total <bytes>              phase <n> <of> <label>
size  <bytes> <disk|zip>   tier  <px> <quality>
image <i> <n>              note  <text>
done  <exit> <path>
```

Unset (the CLI case), every emit is a no-op and terminal behavior is
unchanged. Two details matter: the progress file must live outside the
script's work dir, which its `EXIT` trap deletes; and `disk` and `zip` sizes
are not comparable, so the UI displays only `zip`.

### Why pngquant.py exists

`sips` cannot palette-quantize, so on its own it can only shrink a transparent
PNG by downscaling it. On a real export that is the difference between hitting
the target at good quality and failing at the lowest tier:

| | Result |
|---|---|
| Without a quantizer | 26.7 MB — over target, every image degraded to 1000px/q55 |
| With `pngquant.py` | **23.3 MB** — under target at 1600px/q75 |

`pngquant.py` uses only the Python standard library plus the system ImageIO
framework via `ctypes`, so it needs no installed packages. Pillow is used
automatically when present, purely because it is faster.

Two details worth preserving if this is ever modified:

- Decode uses `kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big`
  (`1|(4<<12)`), which yields RGBA directly. Other flag combinations return
  BGRA and silently produce wrong colors.
- The palette is built from a capped sample of the most frequent colors.
  Running median cut over every distinct color is ~20x slower and yields a
  visually identical result.

## Distribution

The app is ad-hoc signed, not notarized. `install.sh` clears the quarantine
flag after installing, so users never see the "unidentified developer" prompt —
running the installer is the same trust decision that dialog asks for.

Someone who downloads the release zip **manually** (rather than via the
installer) still gets that prompt and needs one right-click → Open.

`build-app.sh` re-signs after patching `Info.plist`. This matters: an app whose
signature does not match its contents is refused outright with *"plist or
signature have been modified"*, rather than showing the ordinary prompt that
right-click → Open clears.

To make manual downloads prompt-free too, sign and notarize with an Apple
Developer ID — commands are at the bottom of INSTALL.md.
