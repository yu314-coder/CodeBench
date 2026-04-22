#!/usr/bin/env python3
"""Audit wheel compatibility for OfflinAi embedded Python on iOS."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


def is_supported_wheel(filename: str) -> bool:
    lower = filename.lower()
    if lower.endswith("-none-any.whl"):
        return True
    if "-ios_" in lower and ("_iphoneos.whl" in lower or "_iphonesimulator.whl" in lower):
        return True
    return False


def summarize(root: pathlib.Path) -> int:
    wheels_dir = root / "app_packages" / "wheels"
    if not wheels_dir.exists():
        print(f"Missing wheels directory: {wheels_dir}")
        return 1

    wheels = sorted(wheels_dir.glob("*.whl"))
    if not wheels:
        print(f"No wheels found in {wheels_dir}")
        return 1

    package_counts: dict[str, int] = {}
    incompatible = []
    for wheel in wheels:
        name = wheel.name
        pkg_name = re.split(r"-\d", name, maxsplit=1)[0]
        package_counts[pkg_name] = package_counts.get(pkg_name, 0) + 1
        if is_supported_wheel(name):
            print(f"OK     {name}")
        else:
            print(f"SKIP   {name}")
            incompatible.append(name)

    print("\nPackage coverage:")
    for pkg in sorted(package_counts):
        print(f" - {pkg}: {package_counts[pkg]} wheel(s)")

    if incompatible:
        print("\nIncompatible wheels detected (non-iOS binary tags).")
        print("Use iOS wheels or pure '-none-any' wheels.")
        return 2

    print("\nAll wheels are compatible with OfflinAi packaging rules.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=pathlib.Path(__file__).resolve().parents[1],
        type=pathlib.Path,
        help="Project root (defaults to repository root).",
    )
    args = parser.parse_args()
    return summarize(args.root)


if __name__ == "__main__":
    sys.exit(main())
