# Shrink Design Zip

Makes Claude Design `.zip` exports small enough to upload. A 778 MB export
becomes about 23 MB — around 97% smaller — with no visible quality loss.

Nothing to install. It uses tools that are already on every Mac.

---

## Setup (once, about 30 seconds)

**1. Move the app to Applications**

Drag `Shrink Design Zip.app` into your **Applications** folder.

**2. Open it the first time**

macOS blocks apps that did not come from the App Store, so the first launch
needs one extra step:

> **Right-click** (or Control-click) the app → choose **Open** → click **Open**
> in the dialog.

You only do this once. After that it opens like any other app.

If you double-click it by mistake and see *"cannot be opened because the
developer cannot be verified"*, just click **OK** and follow the step above.

---

## Using it

**Drag your `.zip` onto the app icon.** That is the whole thing.

You can drop it on the icon in Applications, on the Dock icon, or on the app
window. You can also double-click the app and pick a file.

While it works you will see a notification. It usually takes **30 to 90
seconds** depending on how big the export is.

When it finishes you get a summary:

```
Done.

777.8 MB  →  23.3 MB   (97% smaller)

Saved as:
Topic page-optimized.zip
```

Click **Show in Finder** and the new file is selected, ready to drag into
whatever you are uploading to.

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
