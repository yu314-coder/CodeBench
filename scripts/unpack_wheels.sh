#!/bin/sh
set -e

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WHEEL_DIR="$ROOT_DIR/app_packages/wheels"
TARGET_DIR="$ROOT_DIR/app_packages/site-packages"
STRICT_MODE=0

if [ "${1:-}" = "--strict" ]; then
    STRICT_MODE=1
fi

export ROOT_DIR
export WHEEL_DIR
export TARGET_DIR
export STRICT_MODE

mkdir -p "$TARGET_DIR"

python3 - <<'PY'
import os, glob, zipfile

root = os.environ.get("ROOT_DIR")
wheel_dir = os.environ.get("WHEEL_DIR")
target_dir = os.environ.get("TARGET_DIR")
strict = os.environ.get("STRICT_MODE") == "1"

def wheel_is_supported(filename: str) -> bool:
    lower = filename.lower()
    # Pure-python wheels are always compatible.
    if lower.endswith("-none-any.whl"):
        return True
    # PEP 730 iOS wheel tags.
    if "-ios_" in lower and ("_iphoneos.whl" in lower or "_iphonesimulator.whl" in lower):
        return True
    return False

wheels = sorted(glob.glob(os.path.join(wheel_dir, "*.whl")))
if not wheels:
    print("No wheels found in", wheel_dir)
    raise SystemExit(1)

extracted = []
skipped = []
for whl in wheels:
    filename = os.path.basename(whl)
    if not wheel_is_supported(filename):
        skipped.append(filename)
        print("Skipping incompatible wheel:", filename)
        continue
    print("Unpacking", filename)
    with zipfile.ZipFile(whl) as zf:
        zf.extractall(target_dir)
    extracted.append(filename)

if not extracted:
    print("No compatible wheels extracted.")
    if strict:
        raise SystemExit(2)

if skipped:
    print("\nIncompatible wheels were skipped:")
    for filename in skipped:
        print(" -", filename)
    print("\nTip: use iOS wheel tags ('-ios_*_iphoneos.whl' / '-ios_*_iphonesimulator.whl') or pure '-none-any.whl'.")
    if strict:
        raise SystemExit(3)

print("Done. Extracted to", target_dir)
PY
