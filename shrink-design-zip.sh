#!/bin/bash
#
# shrink-design-zip.sh — Shrink a Claude Design export ZIP for upload.
#
# Usage:  ./shrink-design-zip.sh "Topic page.zip" [target_mb]
#
# Writes "<name>-optimized.zip" next to the original. The original is never
# modified.
#
# Three steps, cheapest first, stopping as soon as the target is met:
#   1. Remove orphans     — images no file references
#   2. Remove duplicates  — byte-identical copies, references repointed
#   3. Shrink images      — resize + recompress, escalating through quality
#                           tiers until the ZIP fits
#
# Runs on macOS built-ins alone: sips, zip, md5, and the system python3.
# Nothing needs to be installed.
#
# Transparent PNGs are handled by pngquant.py, which sits next to this script and
# uses only the Python standard library plus the system ImageIO framework. Pillow
# is used instead when it happens to be installed, purely because it is faster.

set -uo pipefail

TARGET_MB="${2:-25}"
QUALITY_TIERS=("2000:82" "1600:75" "1200:65" "1000:55")
# Files that can reference an image. Scanned to decide what is in use.
TEXT_EXT=(html htm jsx tsx js json css svg md txt)
# File types treated as prunable/compressible. Never code or fonts.
RASTER_EXT=(png jpg jpeg webp)
VIDEO_EXT=(mp4 mov)

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'
say()  { printf "%s\n" "$*"; }
step() { printf "\n${BLD}${BLU}==> %s${RST}\n" "$*"; }
ok()   { printf "    ${GRN}✓${RST} %s\n" "$*"; }
warn() { printf "    ${YEL}!${RST} %s\n" "$*"; }
die()  { printf "${RED}error:${RST} %s\n" "$*" >&2; exit 1; }

mb()      { awk -v b="$1" 'BEGIN{printf "%.1f MB", b/1048576}'; }
dir_size(){ find "$1" -type f -print0 2>/dev/null | xargs -0 stat -f%z 2>/dev/null | awk '{s+=$1} END{printf "%d", s+0}'; }

# ---------------------------------------------------------------- setup ----
[ $# -ge 1 ] || die "usage: $(basename "$0") <design.zip> [target_mb]"
SRC="$1"
[ -f "$SRC" ] || die "no such file: $SRC"
case "$SRC" in *.zip|*.ZIP) ;; *) die "not a .zip file: $SRC" ;; esac
command -v sips >/dev/null || die "sips not found (expected on macOS)"
command -v zip  >/dev/null || die "zip not found"

# md5 lives in /sbin, which is on the default macOS PATH but not on a stripped
# one. Resolve it explicitly so dedup never silently finds zero duplicates.
MD5="$(command -v md5 || true)"
[ -z "$MD5" ] && [ -x /sbin/md5 ] && MD5=/sbin/md5

# python3 drives the path-accurate reference rewriting used by dedup. On a
# stock Mac /usr/bin/python3 exists as a stub that only triggers the Command
# Line Tools installer, so probe by running it rather than by testing for the
# file. Without a working python3, dedup is skipped rather than risking a
# broken reference.
# Prefer /usr/bin/python3 so behavior matches a stock Mac rather than whatever
# Homebrew or pyenv happens to put first on PATH.
HAVE_PY=no
PY=""
for cand in /usr/bin/python3 python3; do
  if "$cand" -c 'pass' >/dev/null 2>&1; then PY="$cand"; HAVE_PY=yes; break; fi
done

# sips cannot palette-quantize, so on its own it can only shrink a transparent
# PNG by downscaling it. pngquant.py does the quantization using nothing but the
# Python standard library and the system ImageIO framework, so it needs no
# installed packages. Pillow is used when present only because it is faster.
HAVE_PIL=no
[ "$HAVE_PY" = "yes" ] && "$PY" -c 'import PIL' >/dev/null 2>&1 && HAVE_PIL=yes

# Look for pngquant.py next to this script.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PNGQUANT=""
[ -f "$SELF_DIR/pngquant.py" ] && PNGQUANT="$SELF_DIR/pngquant.py"
[ -z "$PNGQUANT" ] && [ -f "$SELF_DIR/build/pngquant.py" ] && PNGQUANT="$SELF_DIR/build/pngquant.py"

SRC_DIR="$(cd "$(dirname "$SRC")" && pwd)"
BASE="$(basename "$SRC")"; BASE="${BASE%.*}"
OUT="$SRC_DIR/$BASE-optimized.zip"
ORIG_BYTES=$(stat -f%z "$SRC")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shrinkzip.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/tree"; mkdir -p "$TREE"

printf "${BLD}Shrinking:${RST} %s ${DIM}(%s)${RST}\n" "$(basename "$SRC")" "$(mb "$ORIG_BYTES")"
printf "${BLD}Target:${RST}    under %s MB\n" "$TARGET_MB"

# -o overwrites without prompting: exports often contain names that collide on
# case-insensitive macOS filesystems (e.g. "photo.png" and "Photo.png").
unzip -qo "$SRC" -d "$TREE" || die "could not unzip $SRC"
find "$TREE" -name '__MACOSX' -type d -prune -exec rm -rf {} + 2>/dev/null
find "$TREE" -name '.DS_Store' -delete 2>/dev/null

# macOS filesystems are case-insensitive, so "Photo.png" and "photo.png" cannot
# both exist after extraction and -o keeps only the last one. Harmless on a Mac,
# but worth flagging if the files are headed for a case-sensitive server.
collisions=$(unzip -l "$SRC" | awk '{ $1=$2=$3=""; sub(/^ +/,""); print }' \
  | grep -vE '/$|^$' | tr '[:upper:]' '[:lower:]' | sort | uniq -d | grep -c . || true)
[ "${collisions:-0}" -gt 0 ] && \
  warn "${collisions} filename(s) differ only by capitalization; macOS keeps one of each"

# Build reusable find-expressions for the extension groups.
build_expr() { local first=1; EXPR=(); for e in "$@"; do
    [ $first -eq 1 ] && EXPR+=( -name "*.$e" ) || EXPR+=( -o -name "*.$e" ); first=0
  done; }

find_text()  { build_expr "${TEXT_EXT[@]}";   find "$TREE" -type f \( "${EXPR[@]}" \) -print0; }
find_media() { build_expr "${RASTER_EXT[@]}" "${VIDEO_EXT[@]}"; find "$TREE" -type f \( "${EXPR[@]}" \) -print0; }
find_raster(){ build_expr "${RASTER_EXT[@]}"; find "$TREE" -type f \( "${EXPR[@]}" \) -print0; }

# Collect every basename mentioned by any text file. Matching by basename (not
# full path) because exports reference the same asset from several roots.
# The {1,200} bound matters: exports embed base64 fonts as single 70KB tokens
# and an unbounded pattern degrades badly on them.
scan_refs() {
  find_text | xargs -0 grep -ohE '[A-Za-z0-9_.@%()+-]{1,200}\.(png|jpg|jpeg|webp|mp4|mov)' 2>/dev/null \
    | sed 's|.*/||' | sort -u
}

# Rewrite every occurrence of one basename to another, across all text files.
# Used by both dedup and the format change from .png to .jpg.
rewrite_refs() {
  local from="$1" to="$2"
  [ "$from" = "$to" ] && return 0
  find_text | xargs -0 perl -pi -e "s/\Q$from\E/$to/g" 2>/dev/null
}

report_line() { printf "    %-22s %s\n" "$1" "$2"; }

# Repoint references from one asset to another, by PATH rather than basename.
# For each text file, every image reference is resolved to a tree-relative path.
# If it resolves to the deleted duplicate, it is rewritten to the path of the
# survivor expressed relative to that same text file. Keeps ../ and nested
# references correct instead of grafting a bare filename onto a wrong folder.
# Takes a tab-separated map file of "deleted_path<TAB>surviving_path" and
# applies every rewrite in ONE walk of the tree.
py_rewrite_all() {
  # Written to a file and run by path. Feeding the program on stdin would
  # consume the caller's stdin and stall the surrounding read loop.
  cat > "$WORK/rewrite.py" <<'PY'
import os, re, posixpath
tree = os.environ["TREE"]
mapping = {}
with open(os.environ["MAPFILE"], encoding="utf-8", errors="surrogateescape") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        dup, keep = line.split("\t", 1)
        mapping[dup] = keep
# Some references are bare filenames resolved by a bundler rather than by
# directory. Map those by basename too, but only when the name is unambiguous.
by_base = {}
for dup, keep in mapping.items():
    by_base.setdefault(posixpath.basename(dup), set()).add(keep)
base_map = {b: next(iter(v)) for b, v in by_base.items() if len(v) == 1}
# Never rewrite a basename that still exists somewhere in the tree.
surviving = set()
for _r, _d, _fs in os.walk(tree):
    for _f in _fs:
        surviving.add(_f)
base_map = {b: k for b, k in base_map.items() if b not in surviving}
exts = ("png","jpg","jpeg","webp","mp4","mov")
# Length-bounded and delimiter-excluding. Design exports embed base64 fonts and
# images as single 70KB+ tokens; an unbounded pattern rescans those from every
# position and takes minutes per file. Real asset paths are far under 200 chars.
pat = re.compile(r'([^"\'\s()<>\\,;:]{1,200}?\.(?:' + "|".join(exts) + r'))\b', re.I)
text_ext = {".html",".htm",".jsx",".tsx",".js",".json",".css",".svg",".md",".txt"}
for root, _dirs, files in os.walk(tree):
    for fn in files:
        if os.path.splitext(fn)[1].lower() not in text_ext:
            continue
        p = os.path.join(root, fn)
        try:
            s = open(p, encoding="utf-8", errors="surrogateescape").read()
        except OSError:
            continue
        base = os.path.relpath(root, tree).replace(os.sep, "/")
        base = "" if base == "." else base
        def sub(m):
            ref = m.group(1)
            if ref.startswith(("http:", "https:", "data:")):
                return ref
            # resolve the reference the way a browser would
            cand = posixpath.normpath(posixpath.join(base, ref.lstrip("/")) if not ref.startswith("/") else ref.lstrip("/"))
            keep = mapping.get(cand)
            if keep is None:
                # Bare-filename reference (no directory part) that a bundler
                # resolves on its own. Fall back to matching on basename.
                if "/" not in ref:
                    keep = base_map.get(ref)
                    if keep is not None:
                        return posixpath.basename(keep)
                return ref
            if ref.startswith("/"):
                return "/" + keep
            return posixpath.relpath(keep, base) if base else keep
        out = pat.sub(sub, s)
        if out != s:
            try:
                open(p, "w", encoding="utf-8", errors="surrogateescape").write(out)
            except OSError:
                pass
PY
  MAPFILE="$1" TREE="$TREE" "$PY" "$WORK/rewrite.py" </dev/null 2>/dev/null
}

# Palette-quantize a transparent PNG. Written once here, then run by path so it
# never competes for stdin inside a read loop.
if [ "$HAVE_PIL" = "yes" ]; then
  cat > "$WORK/quantize.py" <<'PY'
import sys
from PIL import Image
src, dst, px = sys.argv[1], sys.argv[2], int(sys.argv[3])
im = Image.open(src).convert("RGBA")
if max(im.size) > px:                 # never upscale
    im.thumbnail((px, px), Image.LANCZOS)
im.quantize(colors=256, method=Image.FASTOCTREE).save(dst, optimize=True)
PY
fi

# ------------------------------------------------- 1. remove orphans -------
step "Step 1 — Removing orphaned media"
scan_refs > "$WORK/refs.txt"
REF_COUNT=$(wc -l < "$WORK/refs.txt" | tr -d ' ')
orphans=0; orphan_bytes=0
while IFS= read -r -d '' f; do
  b="$(basename "$f")"
  if ! grep -qxF "$b" "$WORK/refs.txt"; then
    orphan_bytes=$((orphan_bytes + $(stat -f%z "$f"))); orphans=$((orphans+1)); rm -f "$f"
  fi
done < <(find_media)
report_line "referenced:" "$REF_COUNT files"
report_line "orphans removed:" "$orphans files ($(mb $orphan_bytes))"
ok "now $(mb "$(dir_size "$TREE")") on disk"

# ------------------------------------------------ 2. remove duplicates -----
step "Step 2 — Removing duplicate media"
# Group by md5. Keep the shortest path as canonical, delete the rest, and
# repoint references so nothing 404s.
: > "$WORK/hashes.txt"
if [ -n "$MD5" ]; then
  while IFS= read -r -d '' f; do
    printf "%s\t%s\n" "$("$MD5" -q "$f" </dev/null)" "$f" >> "$WORK/hashes.txt"
  done < <(find_media)
fi

dupes=0; dupe_bytes=0
if [ -z "$MD5" ]; then
  warn "md5 not found — skipping dedup"
elif [ "$HAVE_PY" = "no" ]; then
  warn "python3 not found — skipping dedup (cannot rewrite references safely)"
elif [ -s "$WORK/hashes.txt" ]; then
  cut -f1 "$WORK/hashes.txt" | sort | uniq -d > "$WORK/dupehashes.txt"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    # shortest path wins as canonical — usually the tidiest location
    keep="$(grep "^$h	" "$WORK/hashes.txt" | cut -f2- | awk '{print length"\t"$0}' | sort -n | head -1 | cut -f2-)"
    keep_rel="${keep#$TREE/}"
    while IFS= read -r f; do
      [ "$f" = "$keep" ] && continue
      [ -f "$f" ] || continue
      dupe_bytes=$((dupe_bytes + $(stat -f%z "$f"))); dupes=$((dupes+1))
      # Rewrite by full relative path, not basename. Two duplicates usually
      # have DIFFERENT names in DIFFERENT directories, so a basename swap can
      # graft the survivor's name onto the loser's directory and invent a path
      # that never existed. Replacing the whole path avoids that.
      rm -f "$f"
      printf '%s\t%s\n' "${f#$TREE/}" "$keep_rel" >> "$WORK/dupmap.txt"
    done < <(grep "^$h	" "$WORK/hashes.txt" | cut -f2-)
  done < "$WORK/dupehashes.txt"
  # One tree walk applies every repoint at once.
  [ -s "$WORK/dupmap.txt" ] && py_rewrite_all "$WORK/dupmap.txt"
fi
report_line "duplicates removed:" "$dupes files ($(mb $dupe_bytes))"
ok "now $(mb "$(dir_size "$TREE")") on disk"

# ---------------------------------------------------- zip + measure --------
zip_and_measure() {
  rm -f "$WORK/out.zip"
  ( cd "$TREE" && zip -qr -X "$WORK/out.zip" . ) || die "zip failed"
  stat -f%z "$WORK/out.zip"
}
# Decimal megabytes, not MiB. Upload limits are almost always quoted in
# decimal, and a file of 25.2 million bytes is "under 25 MiB" but still gets
# rejected by a 25 MB limit.
TARGET_BYTES=$((TARGET_MB * 1000000))
cur=$(zip_and_measure)
printf "\n    zipped: ${BLD}%s${RST}\n" "$(mb "$cur")"
if [ "$cur" -le "$TARGET_BYTES" ]; then
  cp "$WORK/out.zip" "$OUT"
  step "Done — target met without recompressing images"
  printf "    %s → ${GRN}%s${RST}\n    ${BLD}%s${RST}\n" "$(mb "$ORIG_BYTES")" "$(mb "$cur")" "$OUT"
  exit 0
fi

# ------------------------------------------------- 3. shrink images --------
step "Step 3 — Shrinking images"
say "    Still over target. Escalating quality tiers until it fits."

# Transparent PNGs can only be downscaled when there is no quantizer available,
# which is the usual reason a run cannot reach the target. Say so up front.
alpha_png_count=0
if [ "$HAVE_PIL" = "no" ] && { [ -z "$PNGQUANT" ] || [ "$HAVE_PY" = "no" ]; }; then
  while IFS= read -r -d '' f; do
    [ "$(sips -g hasAlpha "$f" </dev/null 2>/dev/null | awk '/hasAlpha/{print $2}')" = "yes" ] \
      && alpha_png_count=$((alpha_png_count+1))
  done < <(build_expr png; find "$TREE" -type f \( "${EXPR[@]}" \) -print0)
  [ "$alpha_png_count" -gt 0 ] && \
    warn "No PNG quantizer available; ${alpha_png_count} transparent PNG(s) can only be downscaled."
fi

# Keep originals so each tier recompresses from full quality, never from an
# already-compressed result (which would compound artifacts).
ORIGS="$WORK/origs"; mkdir -p "$ORIGS"
while IFS= read -r -d '' f; do
  rel="${f#$TREE/}"; mkdir -p "$ORIGS/$(dirname "$rel")"; cp "$f" "$ORIGS/$rel"
done < <(find_raster)

final_tier=""
for tier in "${QUALITY_TIERS[@]}"; do
  px="${tier%%:*}"; q="${tier##*:}"
  printf "\n    ${BLD}tier %spx / quality %s${RST}\n" "$px" "$q"

  converted=0; kept=0
  while IFS= read -r -d '' orig; do
    rel="${orig#$ORIGS/}"
    live="$TREE/$rel"
    # locate current file even if a previous tier renamed .png -> .jpg
    if [ ! -f "$live" ]; then
      alt="$TREE/${rel%.*}.jpg"
      [ -f "$alt" ] && live="$alt" || continue
    fi

    ext="$(printf '%s' "${orig##*.}" | tr '[:upper:]' '[:lower:]')"
    alpha="$(sips -g hasAlpha "$orig" </dev/null 2>/dev/null | awk '/hasAlpha/{print $2}')"
    tmp="$WORK/conv"

    if [ "$ext" = "png" ] && [ "$alpha" = "yes" ]; then
      # Transparency must survive — stay PNG. Palette quantization shrinks
      # these ~6x while keeping the alpha channel, but needs Pillow. Without
      # it, fall back to a plain resize.
      rm -f "$tmp.png"
      if [ "$HAVE_PIL" = "yes" ]; then
        "$PY" "$WORK/quantize.py" "$orig" "$tmp.png" "$px" </dev/null >/dev/null 2>&1
      elif [ -n "$PNGQUANT" ] && [ "$HAVE_PY" = "yes" ]; then
        "$PY" "$PNGQUANT" "$orig" "$tmp.png" "$px" </dev/null >/dev/null 2>&1
      fi
      if [ ! -f "$tmp.png" ]; then
        sips -Z "$px" "$orig" --out "$tmp.png" </dev/null >/dev/null 2>&1 || continue
      fi
      newf="$tmp.png"; target="$TREE/${rel%.*}.png"; newbase="$(basename "$target")"
    else
      # Opaque: JPEG is dramatically smaller than PNG at equal quality.
      rm -f "$tmp.jpg"
      # Only pass -Z when the image is actually larger, so sips never upscales
      # a small asset into a bigger file.
      w="$(sips -g pixelWidth  "$orig" </dev/null 2>/dev/null | awk '/pixelWidth/{print $2}')"
      h="$(sips -g pixelHeight "$orig" </dev/null 2>/dev/null | awk '/pixelHeight/{print $2}')"
      big="$w"; [ "${h:-0}" -gt "${w:-0}" ] 2>/dev/null && big="$h"
      if [ "${big:-0}" -gt "$px" ] 2>/dev/null; then
        sips -s format jpeg -s formatOptions "$q" -Z "$px" "$orig" --out "$tmp.jpg" </dev/null >/dev/null 2>&1 || continue
      else
        sips -s format jpeg -s formatOptions "$q" "$orig" --out "$tmp.jpg" </dev/null >/dev/null 2>&1 || continue
      fi
      newf="$tmp.jpg"; target="$TREE/${rel%.*}.jpg"; newbase="$(basename "$target")"
    fi
    [ -f "$newf" ] || continue

    # Never let a "shrink" make a file bigger than what is already there.
    if [ "$(stat -f%z "$newf")" -ge "$(stat -f%z "$live")" ]; then kept=$((kept+1)); continue; fi

    oldbase="$(basename "$live")"
    [ "$live" != "$target" ] && rm -f "$live"
    mv "$newf" "$target"
    # Extension-only change, so every path form ending in this basename stays
    # valid. Queue it; all renames are applied in one pass after the loop.
    [ "$oldbase" != "$newbase" ] && printf '%s\t%s\n' "$oldbase" "$newbase" >> "$WORK/renames.txt"
    converted=$((converted+1))
  done < <(find "$ORIGS" -type f -print0)

  # Apply this tier's .png -> .jpg renames in a single pass over the text files.
  if [ -s "$WORK/renames.txt" ]; then
    export RENAMES="$WORK/renames.txt"
    find_text | xargs -0 perl -pi -e '
      BEGIN{ open(my $m, "<", $ENV{RENAMES}); while(<$m>){ chomp; my($a,$b)=split/\t/; $R{$a}=$b if defined $b; }
             $re = join("|", map { quotemeta } sort { length($b) <=> length($a) } keys %R); }
      # The lookbehind stops "foo.png" from matching inside "barfoo.png",
      # which would rewrite an unrelated file to a name that does not exist.
      s/(?<![A-Za-z0-9_.\@%()+-])($re)/$R{$1}/g if $re;
    ' 2>/dev/null
    : > "$WORK/renames.txt"
  fi

  cur=$(zip_and_measure)
  printf "    recompressed %d, left alone %d → zipped ${BLD}%s${RST}\n" "$converted" "$kept" "$(mb "$cur")"
  final_tier="${px}px/q${q}"
  [ "$cur" -le "$TARGET_BYTES" ] && { ok "under target"; break; }
  warn "still over ${TARGET_MB} MB"
done

cp "$WORK/out.zip" "$OUT"

# ---------------------------------------------------- verification ---------
step "Verifying references"
# The real pass condition: every image that WAS in the zip and is still
# referenced must resolve. Names referenced but never shipped in the original
# (e.g. strings inside a design-system bundle) are not our problem.
unzip -l "$SRC" | awk '{ $1=$2=$3=""; sub(/^ +/,""); print }' | sed 's|.*/||' | sort -u > "$WORK/orig_names.txt"
missing=0; checked=0
scan_refs > "$WORK/refs2.txt"
while IFS= read -r b; do
  [ -n "$b" ] || continue
  grep -qxF "$b" "$WORK/orig_names.txt" || continue   # never shipped; skip
  checked=$((checked+1))
  # a .png may legitimately now be a .jpg
  if ! find "$TREE" \( -name "$b" -o -name "${b%.*}.jpg" -o -name "${b%.*}.png" \) -print -quit 2>/dev/null | grep -q .; then
    warn "unresolved: $b"; missing=$((missing+1))
  fi
done < "$WORK/refs2.txt"
[ "$missing" -eq 0 ] && ok "all $checked shipped references resolve"

# Path-aware pass. Catches a reference that points at the wrong directory even
# though the basename exists somewhere. Such breakage is usually already in the
# original export, so compare against it and only report what WE caused.
check_paths() { # $1 = tree to check
  local root="$1"
  while IFS= read -r -d '' f; do
    local d; d="$(dirname "$f")"
    grep -ohE '(src|href|url)[[:space:]]*[=:(][[:space:]]*["'"'"'(]?[A-Za-z0-9_./@%()+-]{1,200}\.(png|jpg|jpeg|webp)' "$f" 2>/dev/null \
      | sed -E 's/.*["'"'"'(]//' | sort -u | while read -r r; do
          case "$r" in /*|http*|data:*) continue ;; esac
          [ -f "$d/$r" ] || [ -f "$root/$r" ] || printf '%s\n' "$r"
        done
  done < <(find "$root" -type f \( -name '*.html' -o -name '*.css' \) -print0) | sort -u
}
BEFORE_TREE="$WORK/before"; mkdir -p "$BEFORE_TREE"
unzip -qo "$SRC" -d "$BEFORE_TREE" 2>/dev/null
check_paths "$BEFORE_TREE" > "$WORK/broken_before.txt" 2>/dev/null
check_paths "$TREE"        > "$WORK/broken_after.txt"  2>/dev/null
# A path counts as newly broken only if the same path resolved before. Compare
# on the extension-stripped path so the .png -> .jpg rename is not flagged.
sed -E 's/\.(png|jpg|jpeg|webp)$//' "$WORK/broken_before.txt" | sort -u > "$WORK/bb.txt"
sed -E 's/\.(png|jpg|jpeg|webp)$//' "$WORK/broken_after.txt"  | sort -u > "$WORK/ba.txt"
new_broken=$(comm -13 "$WORK/bb.txt" "$WORK/ba.txt" | grep -c . || true)
pre_broken=$(grep -c . < "$WORK/bb.txt" || true)
if [ "${new_broken:-0}" -gt 0 ]; then
  warn "$new_broken path reference(s) broken by this script:"
  comm -13 "$WORK/bb.txt" "$WORK/ba.txt" | head -10 | sed 's/^/        /'
  missing=$((missing + new_broken))
else
  ok "no path references broken by this script"
fi
[ "${pre_broken:-0}" -gt 0 ] && \
  warn "$pre_broken reference(s) were already broken in the original export (left as-is)"

# ---------------------------------------------------- summary --------------
step "Summary"
report_line "original:" "$(mb "$ORIG_BYTES")"
report_line "optimized:" "$(mb "$cur")"
report_line "reduction:" "$(awk -v a="$ORIG_BYTES" -v b="$cur" 'BEGIN{printf "%.1f%%", (a-b)*100/a}')"
report_line "orphans removed:" "$orphans"
report_line "duplicates removed:" "$dupes"
[ -n "$final_tier" ] && report_line "final image tier:" "$final_tier"
printf "\n    ${BLD}%s${RST}\n" "$OUT"

if [ "$cur" -gt "$TARGET_BYTES" ]; then
  warn "Could not reach ${TARGET_MB} MB even at the lowest tier."
  if [ "${alpha_png_count:-0}" -gt 0 ]; then
    warn "${alpha_png_count} transparent PNG(s) could not be quantized (pngquant.py missing)."
  else
    warn "Remaining size is mostly non-image content."
  fi
  exit 2
fi
if [ "$missing" -gt 0 ]; then
  warn "$missing reference(s) did not resolve — inspect before uploading."
  exit 3
fi
exit 0
