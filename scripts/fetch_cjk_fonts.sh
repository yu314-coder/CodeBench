#!/bin/bash
# fetch_cjk_fonts.sh — download Noto Sans SC + KR for full CJK coverage
# =====================================================================
# CodeBench currently ships NotoSansJP-Regular.otf (~4.5MB) which covers
# Japanese fully but is missing ~3000 Simplified-Chinese-only ideographs
# and all of Korean Hangul. This script downloads:
#
#   NotoSansSC-Regular.otf   ~10MB   Simplified Chinese (covers TC fallback)
#   NotoSansKR-Regular.otf   ~7MB    Korean Hangul + Hanja
#
# into CodeBench/Resources/KaTeX/fonts/. Once present, PythonRuntime.swift
# auto-registers them with manimpango / fontconfig and adds them to the
# <prefer> fallback chain so Pango (manim, matplotlib via Cairo backend),
# PIL, and xelatex can pick CJK glyphs by codepoint.
#
# Run once after cloning:
#     bash scripts/fetch_cjk_fonts.sh
#
# Idempotent: existing files are skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$REPO_ROOT/CodeBench/Resources/KaTeX/fonts"

if [ ! -d "$DEST" ]; then
    echo "fetch_cjk_fonts: $DEST does not exist — wrong project root?" >&2
    exit 1
fi

# Notofonts.github.io publishes static-OTF subset fonts that match the
# already-bundled NotoSansJP-Regular.otf naming scheme (per-script family
# names like "Noto Sans SC" rather than the unified "Noto Sans CJK SC").
# Using subset fonts avoids the 18MB Pan-CJK TTC.
declare -a FONTS=(
  "NotoSansSC-Regular.otf|https://github.com/notofonts/noto-cjk/raw/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf"
  "NotoSansKR-Regular.otf|https://github.com/notofonts/noto-cjk/raw/main/Sans/SubsetOTF/KR/NotoSansKR-Regular.otf"
)

for entry in "${FONTS[@]}"; do
    name="${entry%%|*}"
    url="${entry##*|}"
    out="$DEST/$name"
    if [ -s "$out" ]; then
        echo "  $name already present ($(du -h "$out" | awk '{print $1}'))"
        continue
    fi
    echo "  downloading $name ..."
    # Follow redirects, fail on HTTP errors, retry transient network glitches.
    if ! curl -fL --retry 3 --retry-delay 2 -o "$out.tmp" "$url"; then
        echo "  ⚠ download failed for $name from $url" >&2
        rm -f "$out.tmp"
        exit 2
    fi
    # Sanity check: OTF/TTF files start with magic bytes 'OTTO' or 0x00010000.
    head -c 4 "$out.tmp" | xxd | head -1 | grep -qE "(OTTO|0000 0001)" \
        || { echo "  ⚠ $name doesn't look like a font file" >&2; rm -f "$out.tmp"; exit 3; }
    mv "$out.tmp" "$out"
    echo "  ✓ $name ($(du -h "$out" | awk '{print $1}'))"
done

echo
echo "fetch_cjk_fonts: done. Add these to your Xcode project's Resources"
echo "if they aren't already part of the KaTeX/fonts folder reference:"
ls -la "$DEST"/NotoSans{SC,KR}-Regular.otf 2>/dev/null
