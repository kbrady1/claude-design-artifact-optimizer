# Shrink Design Zip

Makes Claude Design `.zip` exports small enough to upload. A 778 MB export
becomes about 23 MB — around 97% smaller — with no visible quality loss.

Nothing to install. It uses tools that are already on every Mac.

---

## Install (one line)

Open **Terminal** (press `Cmd+Space`, type "Terminal", hit Return) and paste
this:

```
curl -fsSL https://raw.githubusercontent.com/kbrady1/claude-design-artifact-optimizer/main/install.sh | bash
```

That downloads the app, puts it in `~/Applications`, and opens it. Takes about
ten seconds. There is no second step — no dragging, and no
"unidentified developer" warning to click through.

To update later, run the same command again.

---

## Using it

Open the app and you get a window with a drop zone.

**Drag your `.zip` into the window**, or click **Choose File…** to pick one.
Dropping onto the app or Dock icon works too.

While it runs the window shows live progress: which step it is on, and the
size counting down as it shrinks.

```
Original                        Now
777.8 MB          →         23.3 MB

████████████████████░░░░  Image 60 of 97

✓ Removing unused images
✓ Removing duplicates
◌ Shrinking images
○ Verifying
```

It usually takes **30 to 90 seconds** depending on the export.

When it finishes you see the before/after summary and a **Save…** button.
Choose where to put the file — it defaults to the same folder as the original,
so you can just press Return. Finder opens with the new file selected.

---

## What you get

The new file is saved **next to the original**, with `-optimized` added to the
name. For example:

| | |
|---|---|
| You dropped | `Topic page.zip` |
| You get | `Topic page-optimized.zip` |

**Your original is never changed or deleted.** If anything looks wrong, the
original is still sitting right there.

---

## What it actually does

Three passes, stopping as soon as the file is small enough:

1. **Removes unused images.** Exports include the whole upload history, not just
   the images the design uses. This is usually the bulk of the savings.
2. **Removes duplicate images.** The same photo often appears several times
   under different names.
3. **Shrinks the remaining images.** Resizes and recompresses, starting at the
   highest quality and only going lower if it has to.

It checks every image reference afterward, so the design still works.

---

## If something goes wrong

**"Could not shrink that file"**
The file is probably not a Claude Design export, or it is damaged. Try
re-downloading it.

**"Shrunk as far as possible, but it is still over the limit"**
The export has an unusual amount of content that cannot be compressed further.
The file was still saved and is still much smaller — try uploading it anyway.

**Nothing happens when I drag the file on**
Make sure you completed the right-click → Open step above. Until you do, macOS
silently refuses to launch the app.

---

## For engineers

The app is a thin AppleScript wrapper around `shrink-design-zip.sh`, which also
runs standalone:

```bash
./shrink-design-zip.sh "Topic page.zip"        # defaults to a 25 MB target
./shrink-design-zip.sh "Topic page.zip" 10     # custom target, in MB
```

Exit codes: `0` success, `2` target not reached, `3` a reference did not
resolve.

Transparent PNGs are quantized by `pngquant.py`, which uses only the Python
standard library plus the system ImageIO framework through `ctypes` — no
Pillow, no packages. Pillow is used automatically if present, only because it
is faster.

Rebuild the app with:

```bash
./build/build-app.sh      # writes dist/Shrink Design Zip.app
```

To remove the Gatekeeper prompt for everyone, sign and notarize with an Apple
Developer ID:

```bash
codesign --deep --force --options runtime \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  "dist/Shrink Design Zip.app"

xcrun notarytool submit "ShrinkDesignZip.zip" \
  --apple-id you@example.com --team-id TEAMID --wait

xcrun stapler staple "dist/Shrink Design Zip.app"
```
