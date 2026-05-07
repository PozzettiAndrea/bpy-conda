"""
Patch Blender's `build_files/cmake/platform/platform_win32.cmake` so it
respects externally-supplied `-DPYTHON_VERSION` / `-DPYTHON_LIBRARY` /
`-DPYTHON_INCLUDE_DIR` / `-DPYTHON_EXECUTABLE` flags.

Stock Blender's platform_win32.cmake unconditionally:

    unset(PYTHON_VERSION CACHE)
    set(PYTHON_VERSION "3.10" CACHE STRING "Python version")
    set(PYTHON_LIBRARY ${LIBDIR}/python/.../python310.lib)
    set(PYTHON_LIBRARY_DEBUG  ${LIBDIR}/python/.../python310_d.lib)
    set(PYTHON_EXECUTABLE ${LIBDIR}/python/.../python.exe)
    set(PYTHON_INCLUDE_DIR ${LIBDIR}/python/.../include)
    set(PYTHON_NUMPY_INCLUDE_DIRS ${LIBDIR}/python/.../site-packages/numpy/...)

— forcing bpy.pyd to link against the bundle's pinned CPython, regardless
of what the recipe's CMake invocation passes. That makes "off-spec"
combos (3.6+py3.11+, 4.2+py3.12+, 5.1+py3.14) impossible: bpy.pyd ends up
with a `python310.dll` import that the conda env doesn't have, and
`import bpy` fails with "DLL load failed: specified module could not be
found." Linux/macOS aren't affected — their platform_*.cmake files
honor the external -D flags directly.

Patch: comment out the seven offending lines. Subsequent CMake then
falls through to the cache-supplied -D values from build.bat.

Idempotent — re-running over an already-patched file is a no-op.
Works for Blender 3.6 LTS, 4.2 LTS, and 5.x — the line patterns are
identical across LTS branches (line numbers differ but the regex doesn't
care). Run from build.bat BEFORE `cmake -S ...`.

Usage:
    python scripts/patch_blender_win32_python.py "<SRC_DIR>"
"""
from __future__ import annotations
import pathlib
import re
import sys

PATTERNS = (
    # Each pattern is the body of a single line. We comment-out the line
    # by replacing it with `# <orig>  # patched-out by bpy-conda`.
    r'unset\s*\(\s*PYTHON_VERSION\s+CACHE\s*\)',
    r'set\s*\(\s*PYTHON_VERSION\s+"[^"]*"\s+CACHE\s+STRING\s+"[^"]*"\s*\)',
    r'set\s*\(\s*PYTHON_VERSION\s+"\$\{[^}]+\}"\s+CACHE\s+STRING\s+"[^"]*"\s*\)',
    r'set\s*\(\s*PYTHON_LIBRARY\s+\$\{LIBDIR\}/python/[^)]+\)',
    r'set\s*\(\s*PYTHON_LIBRARY_DEBUG\s+\$\{LIBDIR\}/python/[^)]+\)',
    r'set\s*\(\s*PYTHON_EXECUTABLE\s+\$\{LIBDIR\}/python/[^)]+\)',
    r'set\s*\(\s*PYTHON_INCLUDE_DIR\s+\$\{LIBDIR\}/python/[^)]+\)',
    r'set\s*\(\s*PYTHON_NUMPY_INCLUDE_DIRS\s+\$\{LIBDIR\}/python/[^)]+\)',
)
COMBINED = re.compile(
    r'^(?P<indent>\s*)(?P<body>(?:' + r'|'.join(PATTERNS) + r'))\s*$',
    flags=re.MULTILINE,
)
ALREADY_PATCHED = "# patched-out by bpy-conda"


def patch(src_dir: pathlib.Path) -> int:
    target = src_dir / "build_files" / "cmake" / "platform" / "platform_win32.cmake"
    if not target.is_file():
        print(f"WARN: {target} not found — skipping", file=sys.stderr)
        return 0
    text = target.read_text(encoding="utf-8")
    if ALREADY_PATCHED in text:
        print(f"already patched: {target}")
        return 0

    def sub(m: re.Match) -> str:
        return f"{m.group('indent')}# {m.group('body')}  {ALREADY_PATCHED}"

    new, n = COMBINED.subn(sub, text)
    if n == 0:
        print(f"WARN: nothing matched in {target} — Blender may have changed the format")
        return 0
    target.write_text(new, encoding="utf-8")
    print(f"patched {n} line(s) in {target}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(patch(pathlib.Path(sys.argv[1])))
