#!/usr/bin/env bash
# fetch_busytex_assets.sh — download the busytex TeX Live data packages
# that are too big to check into git directly.
#
# Run this once after cloning the CodeBench repo. Grabs ~230 MB of
# pre-built LZ4-compressed TeX Live 2023 data packages from upstream
# busytex's WASM release, drops them into CodeBench/Resources/Busytex/.
# After this, `xcodebuild` will bundle them into CodeBench.app.
#
# Pre-built files we pull (matches busytex.html's DATA_PACKAGES list):
#   texlive-basic.data                       (100 MB)
#   ubuntu-texlive-latex-base.data            (6 MB)
#   ubuntu-texlive-latex-recommended.data     (9 MB)
#   ubuntu-texlive-fonts-recommended.data    (10 MB)
#   ubuntu-texlive-latex-extra.data          (47 MB)
#   ubuntu-texlive-science.data               (9 MB)
#
# The matching .js files ARE checked into the repo (tiny) because they
# carry the package manifests the pipeline's resolver needs.
set -euo pipefail

TAG=build_wasm_4499aa69fd3cf77ad86a47287d9a5193cf5ad993_7936974349_1
REPO=busytex/busytex
DEST="$(cd "$(dirname "$0")/.." && pwd)/CodeBench/Resources/Busytex"
mkdir -p "$DEST"

# Use gh if available, else fall back to curl against the release asset URLs.
if command -v gh >/dev/null 2>&1; then
    echo "fetching busytex data packages via gh ($TAG)..."
    gh release download "$TAG" -R "$REPO" \
        --pattern 'texlive-basic.data' \
        --pattern 'ubuntu-texlive-latex-base.data' \
        --pattern 'ubuntu-texlive-latex-recommended.data' \
        --pattern 'ubuntu-texlive-fonts-recommended.data' \
        --pattern 'ubuntu-texlive-latex-extra.data' \
        --pattern 'ubuntu-texlive-science.data' \
        --dir "$DEST" --clobber
else
    echo "gh not available, falling back to curl..."
    for f in texlive-basic.data \
             ubuntu-texlive-latex-base.data \
             ubuntu-texlive-latex-recommended.data \
             ubuntu-texlive-fonts-recommended.data \
             ubuntu-texlive-latex-extra.data \
             ubuntu-texlive-science.data; do
        echo "  $f"
        curl -sSLk \
            "https://github.com/$REPO/releases/download/$TAG/$f" \
            -o "$DEST/$f"
    done
fi

echo
echo "✓ data packages fetched to: $DEST"
echo "  total:"
du -sh "$DEST"/*.data 2>/dev/null | sort -h
