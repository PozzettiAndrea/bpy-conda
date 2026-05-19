"""
Mangle bundled DLL names in bpy/ to a private "bpy_" namespace.

Why: On Windows, `LoadLibrary` resolves DLL names by **basename match against
already-loaded modules in the process**. If torch (or trimesh[easy]'s embreex,
or anything else that ships its own bundled TBB) loaded `tbb12.dll` first,
`bpy.pyd`'s IAT lookup for `tbb12.dll` returns the already-loaded handle —
even though `bpy/tbb12.dll` sits next to `bpy.pyd`. TBB 2020 and 2021 have
~30% different exported symbols, so this produces `STATUS_ENTRYPOINT_NOT_FOUND`
deep in bpy initialization.

Fix: rename bpy's bundled DLLs to a unique namespace (`bpy_tbb12.dll`,
`bpy_embree4.dll`, ...) and patch the Import Address Table of every other
PE file in bpy/ that imported them. The renamed DLLs can no longer collide
with anyone else's `tbb12.dll` (nobody else ships `bpy_tbb12.dll`), so the
basename-already-loaded cache is bypassed. CPython's loader resolves the
renamed deps via `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR`, which already prepends
the .pyd's directory to the dependency search.

This is the same technique `delvewheel` uses for Python wheels on Windows.
We adapt it for the conda packaging step.

Idempotent: re-running on an already-mangled directory is a no-op.

Usage:
    python scripts/mangle_bpy_dlls.py <bpy_dir>

Requirements:
    py-lief >=0.16 (handles arbitrary-length import-name rewrites and rebuilds
    the import table correctly; `pefile` would require equal-or-shorter names).
"""
from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import lief

PREFIX = "bpy_"

log = logging.getLogger("mangle_bpy_dlls")


def list_pe_files(bpy_dir: Path) -> list[Path]:
    pes: list[Path] = []
    for path in bpy_dir.rglob("*"):
        if path.is_file() and path.suffix.lower() in (".dll", ".pyd"):
            pes.append(path)
    return pes


def build_rename_map(pe_files: list[Path]) -> dict[str, str]:
    """
    Build {old_basename_lower: new_basename} for *.dll files inside bpy/.
    .pyd files are NOT renamed — they're Python extension entry points,
    Python imports them by their fixed module names.
    """
    rename_map: dict[str, str] = {}
    for path in pe_files:
        if path.suffix.lower() != ".dll":
            continue
        basename = path.name
        if basename.lower().startswith(PREFIX.lower()):
            continue
        rename_map[basename.lower()] = PREFIX + basename
    return rename_map


def patch_pe_imports(path: Path, rename_map: dict[str, str]) -> bool:
    """
    Rewrite import entries in the PE at `path` whose name matches the
    rename_map. Returns True iff the file was modified and saved.
    """
    binary = lief.PE.parse(str(path))
    if binary is None:
        raise RuntimeError(f"lief failed to parse {path}")

    changed = False

    for entry in binary.imports:
        old = entry.name.lower()
        if old in rename_map:
            entry.name = rename_map[old]
            changed = True

    delay_imports = getattr(binary, "delay_imports", None)
    if delay_imports is not None:
        for entry in delay_imports:
            old = entry.name.lower()
            if old in rename_map:
                entry.name = rename_map[old]
                changed = True

    if not changed:
        return False

    # lief 0.17+ requires a Builder.config_t passed to Builder().
    # Older lief accepted Builder(binary) with no config. We use the
    # explicit config so the API contract is clear and forward-compatible.
    config = lief.PE.Builder.config_t()
    config.imports = True          # rebuild import directory section
    config.patch_imports = True    # apply our entry.name modifications
    builder = lief.PE.Builder(binary, config)
    builder.build()
    builder.write(str(path))
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bpy_dir", type=Path, help="Path to the bpy/ directory to mangle")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="  %(message)s",
        stream=sys.stdout,
    )

    bpy_dir: Path = args.bpy_dir.resolve()
    if not bpy_dir.is_dir():
        log.error("not a directory: %s", bpy_dir)
        return 1

    log.info("scanning %s", bpy_dir)
    pe_files = list_pe_files(bpy_dir)
    log.info("found %d PE files (.dll + .pyd)", len(pe_files))

    rename_map = build_rename_map(pe_files)
    if not rename_map:
        log.info("nothing to do (already mangled or no in-scope DLLs)")
        return 0

    log.info("rename map (%d entries):", len(rename_map))
    for old, new in sorted(rename_map.items()):
        log.info("  %s -> %s", old, new)

    n_patched = 0
    for path in pe_files:
        try:
            if patch_pe_imports(path, rename_map):
                n_patched += 1
                log.debug("patched IAT: %s", path.relative_to(bpy_dir))
        except Exception as e:
            log.error("FAILED to patch %s: %s", path, e)
            return 1
    log.info("patched IAT in %d PE files", n_patched)

    n_renamed = 0
    for path in pe_files:
        if path.suffix.lower() != ".dll":
            continue
        old_name_lower = path.name.lower()
        if old_name_lower in rename_map:
            new_path = path.with_name(rename_map[old_name_lower])
            try:
                path.rename(new_path)
                n_renamed += 1
                log.debug("renamed: %s -> %s", path.name, new_path.name)
            except OSError as e:
                log.error("FAILED to rename %s -> %s: %s", path.name, new_path.name, e)
                return 1
    log.info("renamed %d DLL files on disk", n_renamed)

    log.info("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
