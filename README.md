# claude-design-artifact-optimizer

Shrinks Claude Design export ZIPs so they can be uploaded. A 778 MB export
becomes about 23 MB — roughly 97% smaller — with no visible quality loss.

Ships as a drag-and-drop Mac app for designers, and as a CLI for everyone else.
Nothing needs to be installed: it uses only `sips`, `zip`, and the system
`python3`.

## For designers

See **[INSTALL.md](INSTALL.md)**. Short version: drag `Shrink Design Zip.app`
to Applications, right-click → Open it once, then drag any design ZIP onto it.

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
| `build/driver.applescript` | App UI: drop handling, progress, dialogs. |
| `build/build-app.sh` | Assembles the `.app` bundle. |

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

The app is ad-hoc signed, so a copy someone downloads or receives over Slack is
quarantined and needs one right-click → Open. That step is documented in
INSTALL.md.

`build-app.sh` re-signs after patching `Info.plist`. This matters: an app whose
signature does not match its plist is refused outright with *"plist or
signature have been modified"*, rather than showing the ordinary prompt that
right-click → Open clears.

To remove the prompt entirely, sign and notarize with an Apple Developer ID —
commands are at the bottom of INSTALL.md.
