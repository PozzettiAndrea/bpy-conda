#!/usr/bin/env python3
"""
Repack a published .conda artifact, stripping the platform suffix from the
build string so anaconda.org's filename indexer parses {name}-{ver}-{build}
correctly.

Old: bpy-5.1.1-py313_osx-arm64.conda  (build="py313_osx-arm64")
New: bpy-5.1.1-py313.conda              (build="py313")

This rewrites:
  - the outer zip's `pkg-{name}-{ver}-{old_build}.tar.zst` entry name -> new build
  - the outer zip's `info-{name}-{ver}-{old_build}.tar.zst` entry name -> new build
  - the inner info tar's `info/index.json`  build field -> new build
  - the outer zip filename                                -> new build

The pkg tarball's payload is copied byte-for-byte (no decompression).

Usage:
  repack_strip_platform.py <input.conda> <output_dir>

Exits 0 on success.
"""
import io
import json
import os
import re
import sys
import tarfile
import zipfile
from pathlib import Path

import zstandard as zstd


CONDA_NAME_RE = re.compile(r"^(?P<name>[^/]+?)-(?P<version>[^-]+)-(?P<build>.+)\.conda$")


def strip_platform_suffix(build: str) -> str:
    """Strip a trailing `_<platform>-<arch>` (e.g. `_osx-arm64`, `_linux-64`)."""
    return re.sub(r"_(osx-arm64|linux-64|win-64|linux-aarch64)$", "", build)


def repack(in_path: Path, out_dir: Path) -> Path:
    fname = in_path.name
    m = CONDA_NAME_RE.match(fname)
    if not m:
        raise ValueError(f"unexpected .conda filename: {fname}")

    name = m.group("name")
    version = m.group("version")
    old_build = m.group("build")
    new_build = strip_platform_suffix(old_build)

    if new_build == old_build:
        raise ValueError(f"no platform suffix to strip in build: {old_build}")

    new_fname = f"{name}-{version}-{new_build}.conda"
    out_path = out_dir / new_fname
    out_dir.mkdir(parents=True, exist_ok=True)

    old_pkg_entry = f"pkg-{name}-{version}-{old_build}.tar.zst"
    old_info_entry = f"info-{name}-{version}-{old_build}.tar.zst"
    new_pkg_entry = f"pkg-{name}-{version}-{new_build}.tar.zst"
    new_info_entry = f"info-{name}-{version}-{new_build}.tar.zst"

    with zipfile.ZipFile(in_path, "r") as zin:
        names = zin.namelist()
        if "metadata.json" not in names:
            raise ValueError(f"missing metadata.json in {fname}")
        if old_pkg_entry not in names:
            raise ValueError(f"missing {old_pkg_entry} in {fname}; have {names}")
        if old_info_entry not in names:
            raise ValueError(f"missing {old_info_entry} in {fname}; have {names}")

        metadata_bytes = zin.read("metadata.json")

        # Stream pkg bytes through (do NOT decompress — that file is huge).
        with zin.open(old_pkg_entry) as pkg_in:
            pkg_bytes = pkg_in.read()

        # Decompress info, modify index.json, recompress.
        with zin.open(old_info_entry) as info_zst:
            info_zst_bytes = info_zst.read()

    dctx = zstd.ZstdDecompressor()
    info_tar_bytes = dctx.decompress(info_zst_bytes, max_output_size=64 * 1024 * 1024)

    # Build new info tar: copy every member, rewriting index.json and
    # any other file that references the old build string. paths.json
    # contents do not include build strings; index.json is the only
    # mandatory rewrite. about.json may or may not — we leave it.
    src_tar = tarfile.open(fileobj=io.BytesIO(info_tar_bytes), mode="r:")
    out_buf = io.BytesIO()
    out_tar = tarfile.open(fileobj=out_buf, mode="w:")

    rewrote_index = False
    for member in src_tar.getmembers():
        f = src_tar.extractfile(member) if member.isfile() else None
        data = f.read() if f else b""
        if member.name in ("./info/index.json", "info/index.json"):
            idx = json.loads(data.decode("utf-8"))
            if idx.get("build") != old_build:
                # If index.json's build was already correct (e.g. just "py313"),
                # there's nothing to fix — but old_build came from the filename
                # so a mismatch is possible if the indexer added the platform
                # only at the filename layer. Trust the filename.
                pass
            idx["build"] = new_build
            data = (json.dumps(idx, indent=2) + "\n").encode("utf-8")
            member.size = len(data)
            rewrote_index = True
        out_tar.addfile(member, io.BytesIO(data) if data else None)

    out_tar.close()
    src_tar.close()

    if not rewrote_index:
        raise RuntimeError(f"info/index.json not found in {fname}")

    cctx = zstd.ZstdCompressor(level=19)
    new_info_zst = cctx.compress(out_buf.getvalue())

    # Write new outer zip. Per CEP-7, metadata.json must be the first entry,
    # uncompressed (ZIP_STORED).
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_STORED) as zout:
        zout.writestr("metadata.json", metadata_bytes)
        zout.writestr(new_pkg_entry, pkg_bytes)
        zout.writestr(new_info_entry, new_info_zst)

    return out_path


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    in_path = Path(argv[1])
    out_dir = Path(argv[2])
    if not in_path.is_file():
        print(f"not a file: {in_path}", file=sys.stderr)
        return 1
    out = repack(in_path, out_dir)
    print(f"wrote {out} ({out.stat().st_size:,} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
