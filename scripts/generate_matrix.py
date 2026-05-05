#!/usr/bin/env python3
"""Generate build matrix from packages/bpy.yml, filtering by inputs and skipping
combos already published to the target anaconda.org channel."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import yaml


PLATFORM_MAP = {
    "linux": {"runner": "ubuntu-22.04", "subdir": "linux-64"},
    "windows": {"runner": "windows-2022", "subdir": "win-64"},
    "osx-arm64": {"runner": "macos-14", "subdir": "osx-arm64"},
}


def load_package_config(package: str) -> dict:
    path = Path(__file__).parent.parent / "packages" / f"{package}.yml"
    with open(path) as f:
        return yaml.safe_load(f)


def get_combinations(config: dict) -> list[dict]:
    """Expand package config into list of {blender_version, python, platform} combos."""
    platforms = config.get("build_matrix", {}).get("platforms", ["linux"])
    combos = []
    for entry in config["build_matrix"]["combinations"]:
        for py in entry["python_versions"]:
            for platform in platforms:
                if platform not in PLATFORM_MAP:
                    continue
                combos.append({
                    "blender_version": entry["blender_version"],
                    "python": py,
                    "platform": platform,
                    "runner": PLATFORM_MAP[platform]["runner"],
                    "subdir": PLATFORM_MAP[platform]["subdir"],
                })
    return combos


def check_existing(channel: str, package: str, version: str, build_string_prefix: str, subdir: str) -> bool:
    """Check if a package with matching build string + subdir already exists on anaconda.org."""
    url = f"https://api.anaconda.org/package/{channel}/{package}/files"
    try:
        result = subprocess.run(
            ["curl", "-sf", url],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            return False
        files = json.loads(result.stdout)
        for f in files:
            basename = f.get("basename", "")
            attrs = f.get("attrs", {}) or {}
            file_subdir = attrs.get("subdir") or f.get("ndarch")
            if (
                build_string_prefix in basename
                and f.get("version") == version
                and (file_subdir == subdir or file_subdir is None)
            ):
                return True
    except (json.JSONDecodeError, subprocess.TimeoutExpired, Exception):
        pass
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", default="bpy")
    parser.add_argument("--python", default="all")
    parser.add_argument("--blender", default="all", help='Blender version filter, e.g. "4.2.20" or "all"')
    parser.add_argument("--platform", default="all")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--channel", default="pozzettiandrea")
    args = parser.parse_args()

    config = load_package_config(args.package)
    combos = get_combinations(config)

    if args.python != "all":
        combos = [c for c in combos if c["python"] == args.python]
    if args.blender != "all":
        combos = [c for c in combos if c["blender_version"] == args.blender]
    if args.platform != "all":
        combos = [c for c in combos if c["platform"] == args.platform]

    matrix = []
    for combo in combos:
        version = combo["blender_version"]
        # Build string mirrors what recipe.yaml produces — keep them in sync.
        build_prefix = f"py{combo['python'].replace('.', '')}_{combo['subdir']}"

        if not args.overwrite:
            if check_existing(args.channel, args.package, version, build_prefix, combo["subdir"]):
                print(f"  SKIP {args.package} {version} {build_prefix} (exists)", file=sys.stderr)
                continue

        matrix.append({
            "package": args.package,
            "blender_version": combo["blender_version"],
            "python": combo["python"],
            "platform": combo["platform"],
            "runner": combo["runner"],
            "subdir": combo["subdir"],
        })

    print(f"  {len(matrix)} builds in matrix", file=sys.stderr)

    output_file = os.environ.get("GITHUB_OUTPUT", "")
    matrix_json = json.dumps(matrix)
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"matrix={matrix_json}\n")
    else:
        print(f"matrix={matrix_json}")


if __name__ == "__main__":
    main()
