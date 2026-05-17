"""
Patch Blender's `source/blender/python/mathutils/mathutils_noise.cc` so it
builds against CPython 3.13+ headers on Windows.

Blender's `mathutils_noise.cc` calls `time(nullptr)` (used as the seed for
the Mersenne-twister) without `#include <ctime>`. Up through CPython 3.12
this happened to work on MSVC because `<Python.h>` transitively pulled in
`<time.h>`. CPython 3.13 tightened header hygiene (PEP 703 / nogil prep)
and stopped re-exporting `<time.h>`, so the build fails on Windows with:

    source\blender\python\mathutils\mathutils_noise.cc(118):
        error C3861: 'time': identifier not found

Linux/macOS aren't affected because libc's `<time.h>` gets pulled in
transitively through some other header in their toolchain include chain;
MSVC's chain doesn't.

Patch: insert `#include <ctime>` immediately after `#include <Python.h>`.
With `<ctime>` MSVC exposes `time` both in `std::` and at global scope,
so the existing `time(nullptr)` call resolves without further edits.

Idempotent — re-running over an already-patched file is a no-op
(detected via the `// patched-in by bpy-conda` marker).

Works for Blender 3.6 LTS, 4.2 LTS, and 5.x — the file is identical in
the relevant lines across all three branches.

Usage:
    python scripts/patch_blender_mathutils_noise.py "<SRC_DIR>"
"""
from __future__ import annotations
import pathlib
import re
import sys

MARKER = "// patched-in by bpy-conda"
INSERTION = f'#include <ctime>  {MARKER}\n'

# Match the `#include <Python.h>` line so we can insert right after it.
PYTHON_H_RE = re.compile(r'^(?P<line>#\s*include\s+[<"]Python\.h[>"]\s*)$', re.MULTILINE)


def patch(src_dir: pathlib.Path) -> int:
    target = src_dir / "source" / "blender" / "python" / "mathutils" / "mathutils_noise.cc"
    if not target.is_file():
        print(f"WARN: {target} not found — skipping", file=sys.stderr)
        return 0

    text = target.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"already patched: {target}")
        return 0

    m = PYTHON_H_RE.search(text)
    if not m:
        print(f"WARN: '#include <Python.h>' not found in {target} — skipping", file=sys.stderr)
        return 0

    # Insert `#include <ctime>` on the line immediately after Python.h.
    new = text[: m.end()] + "\n" + INSERTION + text[m.end():]
    target.write_text(new, encoding="utf-8")
    print(f"patched {target}: inserted #include <ctime> after #include <Python.h>")
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_blender_mathutils_noise.py <SRC_DIR>", file=sys.stderr)
        return 2
    return patch(pathlib.Path(sys.argv[1]).resolve())


if __name__ == "__main__":
    sys.exit(main())
