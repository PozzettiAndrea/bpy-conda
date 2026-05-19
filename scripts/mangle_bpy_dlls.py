"""
Mangle bundled DLL names in bpy/ to a private namespace using pefile.

Why: On Windows, `LoadLibrary` resolves DLL names by **basename match against
already-loaded modules in the process**. If torch (or trimesh[easy]'s embreex,
or anything else that ships its own bundled TBB) loaded `tbb12.dll` first,
`bpy.pyd`'s IAT lookup for `tbb12.dll` returns the already-loaded handle —
even though `bpy/tbb12.dll` sits next to `bpy.pyd`. TBB 2020 and 2021 have
~30% different exported symbols, so this produces `STATUS_ENTRYPOINT_NOT_FOUND`
deep in bpy initialization.

Fix: rename bpy's bundled DLLs to a unique namespace and patch the Import
Address Table of every other PE file in bpy/ that imported them.

Tool choice: **pefile**, not lief.
- lief 0.17's `Builder.config_t` has `imports=True` to rebuild the regular
  import directory, but it has NO equivalent for delay imports. After lief
  writes, the delay-import directory size is zeroed and the embedded delay-
  load IAT entries are left in an inconsistent state, causing PE-load
  failures for any DLL that originally had delay imports (e.g. embree4,
  sycl8, OpenImageDenoise_device_*). Verified empirically against `_3`
  build artifacts.
- pefile modifies imports IN PLACE (no directory rebuild), so both regular
  and delay-import entries survive untouched except for the specific name
  strings we update.

Constraint: pefile in-place writes require the new name ≤ original length.
So we use a single-character substitution scheme: replace the first
character with 'Z' (a letter no other Blender bundle DLL starts with).
- `tbb12.dll`   -> `Zbb12.dll`
- `embree4.dll` -> `Zmbree4.dll`
- `openvdb.dll` -> `Zpenvdb.dll`

Ugly but functional. The Z-prefix is unique to bpy-conda's private
namespace — no other package on Windows ships DLLs with this exact
pattern (their `tbb12.dll` is still `tbb12.dll`, never colliding with
our `Zbb12.dll`). The basename-already-loaded cache cannot interfere.

Idempotent: re-running on an already-mangled directory is a no-op.

Usage:
    python scripts/mangle_bpy_dlls.py <bpy_dir>

Requirements: pefile (any 2023.x+). Available on conda-forge.
"""
from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import pefile

# Single-char substitution at position 0. Z is rare as DLL first-char and
# never appears in Blender's bundle. Lowercase z is also fine but Z reads
# more clearly as "private namespace tag" in directory listings.
PREFIX_CHAR = "Z"

log = logging.getLogger("mangle_bpy_dlls")


def list_pe_files(bpy_dir: Path) -> list[Path]:
    pes: list[Path] = []
    for path in bpy_dir.rglob("*"):
        if path.is_file() and path.suffix.lower() in (".dll", ".pyd"):
            pes.append(path)
    return pes


def mangle_name(original: str) -> str:
    """Replace first char with PREFIX_CHAR. Returns same-length string."""
    if not original:
        return original
    return PREFIX_CHAR + original[1:]


def is_mangled(name: str) -> bool:
    """True if name starts with our private prefix (idempotency check)."""
    return name[:1] == PREFIX_CHAR


def build_rename_map(pe_files: list[Path]) -> dict[str, str]:
    """
    Build {old_basename_lower: new_basename} for *.dll files in bpy/.
    .pyd files are NOT renamed — Python imports them by fixed module names.
    """
    rename_map: dict[str, str] = {}
    for path in pe_files:
        if path.suffix.lower() != ".dll":
            continue
        basename = path.name
        if is_mangled(basename):
            continue
        rename_map[basename.lower()] = mangle_name(basename)
    return rename_map


def patch_pe_imports(path: Path, rename_map: dict[str, str]) -> bool:
    """
    In-place rewrite import entries in the PE at `path` whose DLL name
    matches the rename_map. Modifies both regular and delay imports.
    Returns True iff the file was modified and saved.
    """
    pe = pefile.PE(str(path), fast_load=False)
    changed = False

    # Regular imports
    for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []) or []:
        old_name = entry.dll.decode("ascii", errors="replace")
        old_lower = old_name.lower()
        if old_lower in rename_map:
            new_name = rename_map[old_lower]
            assert len(new_name) == len(old_name), (
                f"length mismatch: {old_name!r} -> {new_name!r}"
            )
            entry.dll = new_name.encode("ascii")
            # pefile stores name at entry.struct.Name (RVA). Write in-place.
            pe.set_bytes_at_rva(
                entry.struct.Name,
                new_name.encode("ascii") + b"\x00",
            )
            changed = True

    # Delay imports (the whole reason we switched away from lief)
    for entry in getattr(pe, "DIRECTORY_ENTRY_DELAY_IMPORT", []) or []:
        old_name = entry.dll.decode("ascii", errors="replace")
        old_lower = old_name.lower()
        if old_lower in rename_map:
            new_name = rename_map[old_lower]
            assert len(new_name) == len(old_name)
            entry.dll = new_name.encode("ascii")
            pe.set_bytes_at_rva(
                entry.struct.szName,
                new_name.encode("ascii") + b"\x00",
            )
            changed = True

    if not changed:
        pe.close()
        return False

    pe.write(filename=str(path))
    pe.close()
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

    # Phase 1: patch all PE imports (both regular and delay).
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

    # Phase 2: rename DLL files on disk.
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
