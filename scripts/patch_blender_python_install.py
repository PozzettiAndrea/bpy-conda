"""
Patch Blender's source/creator/CMakeLists.txt to guard the bundled-Python
stdlib install block with `if(EXISTS ...)`.

Blender's lib bundle ships a Python install at `lib/windows_x64/python/<ver>/`
matching the version Blender's standalone app targets. For Blender 5.1.1
that's only `python/313/`. The cmake_install rules try to copy this bundled
Python stdlib into the install prefix for **every** Python the user builds
bpy against via `-DPYTHON_VERSION` — failing with `file INSTALL cannot find`
when the requested version isn't in the bundle (e.g. py3.14 against 5.1.1).

For WITH_PYTHON_MODULE builds (our case) the user supplies their own Python
via `-DPYTHON_EXECUTABLE`. The bundled Python install is not actually needed
at runtime — it's dead weight that conda's own Python stdlib supersedes.
But Blender's CMake fires the install unconditionally inside the
`if(WITH_PYTHON_INSTALL OR WITH_PYTHON_MODULE)` block.

Patch: add an inner guard `if(EXISTS ${LIBDIR}/python/${_PYTHON_VERSION_NO_DOTS}/lib)`
so when the bundle has a matching Python version we ship it (existing
behavior), and when it doesn't we skip cleanly (was an error, now a no-op).

Idempotent: re-running over an already-patched file is a no-op (detected
via the `# patched-in by bpy-conda` marker).

Works for Blender 3.6 LTS / 4.2 LTS / 5.x — the install block structure
is essentially identical across all three.

Usage:
    python scripts/patch_blender_python_install.py "<SRC_DIR>"
"""
from __future__ import annotations

import pathlib
import re
import sys

MARKER = "# patched-in by bpy-conda: guard bundled-Python install"

# Find the `if(WITH_PYTHON_INSTALL OR WITH_PYTHON_MODULE)` line. The first
# install() block inside it references ${LIBDIR}/python/${_PYTHON_VERSION_NO_DOTS}/lib.
PYTHON_INSTALL_BLOCK_RE = re.compile(
    r'^(\s*)if\s*\(\s*WITH_PYTHON_INSTALL\s+OR\s+WITH_PYTHON_MODULE\s*\)\s*$',
    re.MULTILINE,
)


def patch(src_dir: pathlib.Path) -> int:
    target = src_dir / "source" / "creator" / "CMakeLists.txt"
    if not target.is_file():
        print(f"WARN: {target} not found -- skipping", file=sys.stderr)
        return 0

    text = target.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"already patched: {target}")
        return 0

    m = PYTHON_INSTALL_BLOCK_RE.search(text)
    if not m:
        print(
            f"WARN: 'if(WITH_PYTHON_INSTALL OR WITH_PYTHON_MODULE)' not "
            f"found in {target} -- skipping",
            file=sys.stderr,
        )
        return 0

    indent = m.group(1)
    insertion = (
        f"{indent}  {MARKER}\n"
        f"{indent}  # Skip the bundled-Python-stdlib install when the lib bundle\n"
        f"{indent}  # doesn't ship the requested Python version (e.g. py3.14\n"
        f"{indent}  # against Blender 5.1.1's bundle which only has python/313/).\n"
        f"{indent}  # For WITH_PYTHON_MODULE we use the user-supplied Python anyway.\n"
        f"{indent}  if(NOT EXISTS \"${{LIBDIR}}/python/${{_PYTHON_VERSION_NO_DOTS}}/lib\")\n"
        f"{indent}    message(STATUS \"bpy-conda: bundled Python ${{_PYTHON_VERSION_NO_DOTS}} not in lib bundle; skipping bundled-Python install\")\n"
        f"{indent}    set(_BPY_CONDA_SKIP_PYTHON_INSTALL TRUE)\n"
        f"{indent}  else()\n"
        f"{indent}    set(_BPY_CONDA_SKIP_PYTHON_INSTALL FALSE)\n"
        f"{indent}  endif()\n"
    )

    # Insert right after the `if(WITH_PYTHON_INSTALL OR WITH_PYTHON_MODULE)` line
    new_text = text[: m.end()] + "\n" + insertion + text[m.end():]

    # Now also gate every install() block inside that references
    # ${LIBDIR}/python/${_PYTHON_VERSION_NO_DOTS} with the var we just set.
    # Strategy: wrap each `install(\s*…\$\{LIBDIR\}/python/\$\{_PYTHON_VERSION_NO_DOTS\}…\))`
    # with `if(NOT _BPY_CONDA_SKIP_PYTHON_INSTALL)\n  install(...)\nendif()`.
    # But that requires balanced-paren detection. Easier: just prepend the
    # guard variable check to each install() that mentions the path.
    pattern = re.compile(
        r"(^(\s*)install\s*\([^)]*\$\{LIBDIR\}/python/\$\{_PYTHON_VERSION_NO_DOTS\}[^)]*\)\s*\n)",
        re.MULTILINE | re.DOTALL,
    )
    n_wrapped = 0

    def _wrap(match: re.Match) -> str:
        nonlocal n_wrapped
        n_wrapped += 1
        block = match.group(1)
        indent = match.group(2)
        return (
            f"{indent}if(NOT _BPY_CONDA_SKIP_PYTHON_INSTALL)\n"
            f"{block}"
            f"{indent}endif()\n"
        )

    new_text = pattern.sub(_wrap, new_text)

    target.write_text(new_text, encoding="utf-8")
    print(
        f"patched {target}: inserted bundle-presence guard + wrapped "
        f"{n_wrapped} install() blocks"
    )
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_blender_python_install.py <SRC_DIR>", file=sys.stderr)
        return 2
    return patch(pathlib.Path(sys.argv[1]).resolve())


if __name__ == "__main__":
    sys.exit(main())
