#!/usr/bin/env bash
# Bootstraps the CodeBench workspace by pulling in the python-ios-lib
# runtime and stitching it into the repo root the way Xcode's project
# file expects.
#
# Run from the CodeBench repo root:
#     ./scripts/setup.sh
#
# After it completes you can open `CodeBench.xcodeproj` and build.
#
# The script is idempotent — re-running it just re-verifies the
# symlinks. Pass `--update` to also `git pull` the runtime repo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_REPO_URL="https://github.com/yu314-coder/python-ios-lib"
RUNTIME_DIR="$REPO_ROOT/_vendor/python-ios-lib"

UPDATE=0
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE=1 ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)  echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ─── 1. Fetch / refresh the python-ios-lib runtime ────────────────
if [ ! -d "$RUNTIME_DIR/.git" ]; then
    echo "[setup] Cloning python-ios-lib into _vendor/python-ios-lib/ ..."
    mkdir -p "$(dirname "$RUNTIME_DIR")"
    git clone "$RUNTIME_REPO_URL" "$RUNTIME_DIR"
elif [ "$UPDATE" = "1" ]; then
    echo "[setup] Updating python-ios-lib ..."
    git -C "$RUNTIME_DIR" pull --ff-only
else
    echo "[setup] python-ios-lib already present (re-run with --update to pull)."
fi

# ─── 2. Verify the runtime has what Xcode expects ─────────────────
missing=()
for p in Frameworks/Python.xcframework \
         Frameworks/llama.xcframework \
         Frameworks/ExecuTorch \
         app_packages \
         Monaco \
         Sources \
         Package.swift; do
    [ -e "$RUNTIME_DIR/$p" ] || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "[setup] ERROR: the runtime repo is missing required paths:" >&2
    for p in "${missing[@]}"; do echo "  - $p" >&2; done
    echo "[setup] Re-clone or check the upstream repo state." >&2
    exit 1
fi

# ─── 3. Symlink runtime paths to the CodeBench workspace root ─────
# Xcode's project file references these at the workspace root (same
# level as CodeBench.xcodeproj). Symlinks keep both repos' .git
# histories independent — `git status` in CodeBench/ shows only
# CodeBench changes, and `git pull` inside _vendor/python-ios-lib
# updates the runtime without touching this repo.
cd "$REPO_ROOT"
linked=()
for item in Frameworks app_packages Monaco Sources Package.swift; do
    target="_vendor/python-ios-lib/$item"
    if [ -L "$item" ]; then
        current=$(readlink "$item")
        if [ "$current" = "$target" ]; then
            continue   # already correct
        fi
        rm "$item"
    elif [ -e "$item" ]; then
        echo "[setup] WARNING: $item exists and is not a symlink — leaving alone." >&2
        echo "[setup]          If you want the script to manage it, remove it first." >&2
        continue
    fi
    ln -s "$target" "$item"
    linked+=("$item")
done

# ─── 4. Done ──────────────────────────────────────────────────────
echo ""
echo "[setup] Workspace ready."
if [ ${#linked[@]} -gt 0 ]; then
    echo "[setup] Created/refreshed symlinks: ${linked[*]}"
fi
echo "[setup] Next:  open CodeBench.xcodeproj"
echo "[setup]        select your iPad or 'My Mac (Designed for iPad)' as destination"
echo "[setup]        Product → Run"
