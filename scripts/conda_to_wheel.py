"""Convert a single bpy `.conda` package into a pip-installable `.whl`.

Why: the .conda's `Lib/site-packages/bpy/` tree is already a fully
self-contained Python extension (Z-prefix-mangled DLLs on Windows,
RPATH-relative .so on Linux/macOS) — exactly what a wheel ships.
Repackaging is a layout swap, not a rebuild.

Filename mapping (bpy-conda channel -> wheel filename):
  win-64/bpy-5.1.1-py313.conda  -> bpy-5.1.1-cp313-cp313-win_amd64.whl
  linux-64/bpy-4.2.20-py312.conda -> bpy-4.2.20-cp312-cp312-manylinux_2_28_x86_64.whl
  osx-arm64/bpy-3.6.23-py310.conda -> bpy-3.6.23-cp310-cp310-macosx_14_0_arm64.whl

Linux platform tag: we declare manylinux_2_28 (ubuntu-22.04+ /
glibc 2.28+, what the conda runner builds against). On older glibc
the wheel won't install — acceptable for now; a follow-up can run
`auditwheel repair` to bundle libstdc++ and broaden compatibility.

macOS platform tag: macosx_14_0_arm64 — macOS 14 is what Blender
5.1's CMake requires (Xcode 16+ requirement).

Wheel contents:
  bpy/                              (the module + its bundled libs)
  bpy.pth                           (Windows-only: site.py preload trigger)
  _bpy_dll_preload.py               (Windows-only: lazy DLL preload module)
  bpy-<ver>.dist-info/METADATA
  bpy-<ver>.dist-info/WHEEL
  bpy-<ver>.dist-info/RECORD
  bpy-<ver>.dist-info/top_level.txt

Usage:
    python conda_to_wheel.py <input.conda> <output_dir>
"""
from __future__ import annotations

import base64
import csv
import hashlib
import io
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

from conda_package_handling.api import extract


SUBDIR_TO_PLATFORM_TAG = {
    "win-64": "win_amd64",
    # manylinux_2_28 == RHEL 8 / Ubuntu 18.10+ / Debian 10+ / glibc 2.28+.
    # Matches the ubuntu-22.04 GHA runner that built the .conda.
    "linux-64": "manylinux_2_28_x86_64",
    # macOS 14 is Blender 5.1's minimum (Xcode 16+ requirement). 4.2 and
    # 3.6 builds also use the same runner so the floor is uniform.
    "osx-arm64": "macosx_14_0_arm64",
}

# Per-conda site-packages location. Windows uses Library\Lib on conda but
# the bpy recipes stage into PREFIX\Lib\site-packages directly, while
# Linux/macOS stage into PREFIX/lib/pythonX.Y/site-packages.
def _find_bpy_dir(staging: Path) -> Path:
    """Locate bpy/ inside an extracted .conda staging dir."""
    candidates = list(staging.rglob("site-packages/bpy/__init__.pyd")) + \
                 list(staging.rglob("site-packages/bpy/__init__.so")) + \
                 list(staging.rglob("site-packages/bpy/__init__.cpython-*.so")) + \
                 list(staging.rglob("site-packages/bpy/__init__.cpython-*.dylib"))
    if not candidates:
        # Linux/macOS conda packages may put bpy as bpy.cpython-3XX-*.so
        # at the site-packages root (rather than bpy/__init__.so).
        # Check for `bpy/` dir alone.
        bpy_dirs = [p for p in staging.rglob("site-packages/bpy") if p.is_dir()]
        if bpy_dirs:
            return bpy_dirs[0]
        raise FileNotFoundError(f"no bpy/ found under {staging}")
    return candidates[0].parent


def _sha256_b64(data: bytes) -> str:
    """Wheel RECORD-format hash: 'sha256=<urlsafe-b64-no-padding>'."""
    h = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(h).rstrip(b"=").decode("ascii")


def _build_metadata(version: str, py_minor: str) -> bytes:
    """Wheel METADATA (RFC 822). Requires-Python pins exact CPython minor."""
    py_short = py_minor.replace("cp", "")  # e.g. cp313 -> 313
    py_human = f"{py_short[0]}.{py_short[1:]}"  # 313 -> 3.13
    body = (
        "Metadata-Version: 2.1\n"
        "Name: bpy\n"
        f"Version: {version}\n"
        "Summary: Blender as a Python module — bpy-conda repackaged as a wheel\n"
        "Home-page: https://www.blender.org/\n"
        "Author: Blender Foundation\n"
        "License: GPL-3.0-or-later\n"
        f"Requires-Python: =={py_human}.*\n"
        "Classifier: Programming Language :: Python :: 3\n"
        "Classifier: License :: OSI Approved :: GNU General Public License v3 or later (GPLv3+)\n"
        "Classifier: Operating System :: Microsoft :: Windows\n"
        "Classifier: Operating System :: POSIX :: Linux\n"
        "Classifier: Operating System :: MacOS\n"
        "Description-Content-Type: text/markdown\n"
        "\n"
        f"Blender {version} as a Python module. Repackaged from the\n"
        "[`pozzettiandrea/bpy`](https://anaconda.org/pozzettiandrea/bpy) conda\n"
        "channel; see https://github.com/PozzettiAndrea/bpy-conda for the build pipeline.\n"
    )
    return body.encode("utf-8")


def _build_wheel_metadata(tag: str) -> bytes:
    """WHEEL file. Tag is e.g. 'cp313-cp313-win_amd64'."""
    body = (
        "Wheel-Version: 1.0\n"
        "Generator: bpy-conda conda_to_wheel.py\n"
        "Root-Is-Purelib: false\n"
        f"Tag: {tag}\n"
    )
    return body.encode("utf-8")


def _build_top_level() -> bytes:
    return b"bpy\n"


def repackage(conda_path: Path, out_dir: Path) -> Path:
    """Extract conda_path, build the .whl, return its path."""
    out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="bpy_conda_to_wheel_") as td:
        staging = Path(td) / "staging"
        staging.mkdir()
        extract(str(conda_path), dest_dir=str(staging))

        index = json.loads((staging / "info" / "index.json").read_text())
        version = index["version"]
        subdir = index["subdir"]
        platform_tag = SUBDIR_TO_PLATFORM_TAG.get(subdir)
        if not platform_tag:
            raise ValueError(f"unsupported subdir: {subdir}")

        # Build string e.g. "py313_win-64_4" -> python tag cp313.
        build = index["build"]
        m = re.match(r"py(\d+)(?:_|$)", build)
        if not m:
            raise ValueError(f"can't parse python tag from build string: {build}")
        py_short = m.group(1)
        py_tag = f"cp{py_short}"
        abi_tag = py_tag  # CPython ABI tag == python tag for our wheels.

        full_tag = f"{py_tag}-{abi_tag}-{platform_tag}"
        whl_name = f"bpy-{version}-{full_tag}.whl"
        out_path = out_dir / whl_name

        bpy_dir = _find_bpy_dir(staging)
        site_pkg = bpy_dir.parent

        dist_info_name = f"bpy-{version}.dist-info"
        records: list[tuple[str, str, int]] = []

        with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
            def add(arcname: str, data: bytes) -> None:
                zf.writestr(arcname, data)
                records.append((arcname, _sha256_b64(data), len(data)))

            def add_file(arcname: str, src: Path) -> None:
                data = src.read_bytes()
                add(arcname, data)

            # bpy/ tree at wheel root.
            for path in sorted(bpy_dir.rglob("*")):
                if path.is_file() or path.is_symlink():
                    rel = path.relative_to(site_pkg)
                    add_file(str(rel).replace("\\", "/"), path)

            # Windows-only: bpy.pth + _bpy_dll_preload.py also live in
            # site-packages root and must drop into Python's site-packages.
            # Wheels install root-level files to purelib, which is the
            # site-packages directory (Root-Is-Purelib=false notwithstanding —
            # for non-pure wheels with platlib, root-level files go to
            # platlib which still resolves to site-packages on CPython).
            for extra in ("bpy.pth", "_bpy_dll_preload.py"):
                src = site_pkg / extra
                if src.is_file():
                    add_file(extra, src)

            # dist-info.
            add(f"{dist_info_name}/METADATA", _build_metadata(version, py_tag))
            add(f"{dist_info_name}/WHEEL", _build_wheel_metadata(full_tag))
            add(f"{dist_info_name}/top_level.txt", _build_top_level())

            # RECORD must list itself with empty hash/size (PEP 427).
            record_lines = io.StringIO()
            w = csv.writer(record_lines, lineterminator="\n")
            for arcname, digest, size in records:
                w.writerow([arcname, digest, size])
            w.writerow([f"{dist_info_name}/RECORD", "", ""])
            zf.writestr(f"{dist_info_name}/RECORD", record_lines.getvalue())

        print(f"==> wrote {out_path} ({out_path.stat().st_size:,} bytes)")
        return out_path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: conda_to_wheel.py <input.conda> <output_dir>", file=sys.stderr)
        return 2
    conda_path = Path(sys.argv[1]).resolve()
    out_dir = Path(sys.argv[2]).resolve()
    if not conda_path.is_file():
        print(f"not found: {conda_path}", file=sys.stderr)
        return 1
    repackage(conda_path, out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
