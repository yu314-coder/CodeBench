#!/usr/bin/env python3
"""Download iOS-compatible wheels from a simple package index.

This targets OfflinAi's embedded Python runtime and fetches wheel files into
app_packages/wheels for later unpacking.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import urllib.parse
import urllib.request
import urllib.error

DEFAULT_INDEX = "https://pypi.anaconda.org/beeware/simple"
DEFAULT_PACKAGES = ["numpy", "cffi", "matplotlib", "scipy", "scikit-learn", "manim"]
DEFAULT_PLATFORMS = [
    "ios_17_0_arm64_iphoneos",
    "ios_17_0_arm64_iphonesimulator",
    "ios_17_0_x86_64_iphonesimulator",
    "ios_13_0_arm64_iphoneos",
    "ios_13_0_arm64_iphonesimulator",
    "ios_13_0_x86_64_iphonesimulator",
]


def normalize_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def version_key(version: str):
    parts = re.split(r"([0-9]+)", version)
    key = []
    for part in parts:
        if not part:
            continue
        if part.isdigit():
            key.append((1, int(part)))
        else:
            key.append((0, part.lower()))
    return tuple(key)


def parse_wheel_metadata(filename: str):
    # Minimal parse: name-version-...-python-abi-platform.whl
    if not filename.endswith(".whl"):
        return None
    stem = filename[:-4]
    parts = stem.split("-")
    if len(parts) < 5:
        return None
    name = "-".join(parts[:-4])
    version = parts[-4]
    python_tag = parts[-3]
    abi_tag = parts[-2]
    platform_tag = parts[-1]
    return {
        "name": normalize_name(name),
        "version": version,
        "python_tag": python_tag,
        "abi_tag": abi_tag,
        "platform_tag": platform_tag,
    }


def fetch_simple_links(index_url: str, package: str):
    package_url = index_url.rstrip("/") + "/" + urllib.parse.quote(package) + "/"
    try:
        with urllib.request.urlopen(package_url, timeout=30) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return []
        raise
    links = re.findall(r'href=["\']([^"\']+\.whl)["\']', html, flags=re.IGNORECASE)
    out = []
    for href in links:
        absolute = urllib.parse.urljoin(package_url, href)
        filename = urllib.parse.unquote(urllib.parse.urlparse(absolute).path.split("/")[-1])
        out.append((filename, absolute))
    return out


def choose_latest_per_platform(candidates):
    latest = {}
    for entry in candidates:
        platform = entry["platform_tag"]
        current = latest.get(platform)
        if current is None or version_key(entry["version"]) > version_key(current["version"]):
            latest[platform] = entry
    return [latest[k] for k in sorted(latest)]


def download_file(url: str, destination: pathlib.Path):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        print(f"SKIP   {destination.name} (already exists)")
        return
    print(f"GET    {destination.name}")
    with urllib.request.urlopen(url, timeout=60) as resp, destination.open("wb") as fp:
        while True:
            chunk = resp.read(1024 * 128)
            if not chunk:
                break
            fp.write(chunk)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", default=DEFAULT_INDEX, help="Simple index base URL.")
    parser.add_argument("--python-tag", default="cp314", help="Python tag to match, e.g. cp314.")
    parser.add_argument(
        "--packages",
        nargs="+",
        default=DEFAULT_PACKAGES,
        help="Packages to query.",
    )
    parser.add_argument(
        "--platform",
        nargs="+",
        default=DEFAULT_PLATFORMS,
        help="Allowed wheel platform tags.",
    )
    parser.add_argument(
        "--output-dir",
        default=str(pathlib.Path(__file__).resolve().parents[1] / "app_packages" / "wheels"),
        help="Directory where wheel files are saved.",
    )
    parser.add_argument(
        "--include-none-any",
        action="store_true",
        help="Also include pure python wheels (-none-any.whl).",
    )
    args = parser.parse_args()

    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    any_downloaded = False
    had_error = False
    for package in args.packages:
        print(f"\n## {package}")
        try:
            links = fetch_simple_links(args.index, package)
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR  failed to query index for {package}: {exc}")
            had_error = True
            continue

        filtered = []
        target_name = normalize_name(package)
        for filename, url in links:
            meta = parse_wheel_metadata(filename)
            if meta is None:
                continue
            if normalize_name(meta["name"]) != target_name:
                continue

            is_ios = "ios_" in meta["platform_tag"]
            if is_ios:
                if meta["python_tag"] != args.python_tag:
                    continue
                if meta["platform_tag"] not in args.platform:
                    continue
                filtered.append({**meta, "filename": filename, "url": url})
                continue

            if args.include_none_any and meta["platform_tag"] == "any" and meta["abi_tag"] == "none":
                if meta["python_tag"] in {"py3", "py2.py3", args.python_tag}:
                    filtered.append({**meta, "filename": filename, "url": url})

        if not filtered:
            print("NONE   no compatible wheels found")
            continue

        chosen = choose_latest_per_platform(filtered)
        for entry in chosen:
            destination = output_dir / entry["filename"]
            try:
                download_file(entry["url"], destination)
                any_downloaded = True
            except Exception as exc:  # noqa: BLE001
                print(f"ERROR  download failed for {entry['filename']}: {exc}")
                had_error = True

    print("\nDone.")
    print(f"Output directory: {output_dir}")
    if had_error:
        return 2
    if not any_downloaded:
        print("No new wheels were downloaded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
