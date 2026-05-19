"""
Write `bpy.pth` and `_bpy_dll_preload.py` into <site_packages>.

Background: Windows' DLL loader doesn't propagate
`LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` through deep transitive
dependency chains. When `import bpy` triggers `LoadLibraryEx` on
`bpy/__init__.pyd`, only its IMMEDIATE deps get `bpy/` prepended
to their search path. Deeper transitive deps (e.g., `Zmbree4.dll`
needs `Zycl8.dll` needs `Zr_win_proxy_loader.dll`) are resolved
against the default DLL search path — which does NOT include `bpy/`.

The fix: explicitly `LoadLibrary` the eager-IAT closure of
`bpy/__init__.pyd` into the process basename cache so that when
`bpy.pyd` later loads, every transitive dep already resolves via
basename hit.

The cost-vs-trigger choice: load EAGER (every Python startup in any
env that has bpy installed) or LAZY (only on `import bpy`).

Eager (the original implementation) wedges pixi-style env probes
that just want to query `sys.executable` or run a one-liner JSON
dump — they pay the full DLL load cost AND hit a teardown
STATUS_ACCESS_VIOLATION (0xC0000005) inside one of the bundled
runtime DLLs. That broke comfy-gpu-ci's windows-portable-gpu
matrix across every workflow that had bpy in its env.

Lazy via sys.meta_path is what we ship now. `_bpy_dll_preload.py`
registers a MetaPathFinder; the actual DLL loads only fire when
something tries to `import bpy`.

We also restrict the preload set to the EAGER closure of
`__init__.pyd`'s import table — ~36 DLLs on 5.1.1, vs all 107
bundled DLLs (which includes lazy GPU device variants, debug
variants, optional addon DLLs etc.). Computing this closure
requires `pefile`; if it's not available in the build env we
install it via pip.

Usage:
    python scripts/write_bpy_preload.py <site_packages_dir>
"""
from __future__ import annotations

import subprocess
import sys
from collections import OrderedDict
from pathlib import Path


def _ensure_pefile():
    try:
        import pefile  # noqa: F401
        return
    except ImportError:
        pass
    print("==> pefile missing; installing", flush=True)
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "--quiet", "pefile"]
    )


def _compute_closure(bpy_dir: Path) -> list[str]:
    """Eager-IAT closure of __init__.pyd, deps-first topological order.

    Walks DIRECTORY_ENTRY_IMPORT recursively. Skips DIRECTORY_ENTRY_DELAY_IMPORT
    on purpose — delay-imports are resolved on first use, not at LoadLibrary
    time, so they don't need to be in the process basename cache when bpy.pyd
    loads.
    """
    import pefile

    init_pyd = bpy_dir / "__init__.pyd"
    if not init_pyd.is_file():
        raise FileNotFoundError(init_pyd)

    visited: set[Path] = set()
    ordered: "OrderedDict[str, str]" = OrderedDict()

    def walk(path: Path) -> None:
        if path in visited:
            return
        visited.add(path)
        try:
            pe = pefile.PE(str(path), fast_load=False)
        except Exception as e:
            print(f"WARN: failed to parse {path}: {e}", file=sys.stderr)
            return
        for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []) or []:
            dep_name = entry.dll.decode("ascii", errors="replace")
            dep_lower = dep_name.lower()
            dep_path = bpy_dir / dep_name
            if not dep_path.is_file():
                continue
            if dep_lower not in ordered:
                walk(dep_path)
                ordered[dep_lower] = dep_name
        pe.close()

    walk(init_pyd)
    return list(ordered.values())


PTH_CONTENT = "import _bpy_dll_preload\n"

PRELOAD_TEMPLATE = '''"""Lazy preload of bpy/'s mangled DLLs.

Triggered only on `import bpy` via a sys.meta_path hook — NOT at
Python startup. Envs that have bpy installed but don't use it pay
zero cost (no DLL loads, no teardown crashes).

Mechanism:
1. bpy.pth runs `import _bpy_dll_preload` at site.py time, which
   registers a MetaPathFinder.
2. The finder's `find_spec("bpy", ...)` fires on the first
   `import bpy`. It loads the eager closure of bpy.pyd's IAT
   into the process basename cache, then returns None to let the
   normal import machinery proceed.
3. bpy.pyd then loads with all transitive deps already resolved
   (Windows basename-cache hit), regardless of
   LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR's failure to propagate
   through deep transitive chains.

The eager closure is computed at build time by walking
__init__.pyd's PE IAT. Only DLLs that bpy.pyd actually needs at
import time are listed — GPU device DLLs, debug variants, and
optional addon DLLs are excluded.
"""
import os
import sys
import ctypes
from importlib.abc import MetaPathFinder


_EAGER_CLOSURE = [
__CLOSURE_LINES__
]


class _BpyPreloadFinder(MetaPathFinder):
    """sys.meta_path entry that triggers DLL preload on first `import bpy`."""

    _fired = False

    def find_spec(self, name, path, target=None):
        if name != "bpy" or _BpyPreloadFinder._fired:
            return None
        _BpyPreloadFinder._fired = True
        self._preload()
        return None  # delegate to next finder

    def _preload(self):
        import site
        for sp in site.getsitepackages():
            bpy_dir = os.path.join(sp, "bpy")
            if not os.path.isdir(bpy_dir):
                continue
            os.add_dll_directory(bpy_dir)
            for name in _EAGER_CLOSURE:
                full = os.path.join(bpy_dir, name)
                if not os.path.exists(full):
                    continue
                try:
                    ctypes.WinDLL(full)
                except OSError:
                    # Optional/GPU DLLs may fail without their runtime;
                    # bpy itself doesn't need them for `import bpy`.
                    pass
            return


sys.meta_path.insert(0, _BpyPreloadFinder())
'''


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: write_bpy_preload.py <site_packages>", file=sys.stderr)
        return 2

    site_packages = Path(sys.argv[1]).resolve()
    if not site_packages.is_dir():
        print(f"not a directory: {site_packages}", file=sys.stderr)
        return 1

    bpy_dir = site_packages / "bpy"
    if not bpy_dir.is_dir():
        print(f"bpy/ not found in {site_packages}", file=sys.stderr)
        return 1

    _ensure_pefile()
    closure = _compute_closure(bpy_dir)
    print(f"==> eager closure: {len(closure)} DLLs")
    for name in closure:
        print(f"   {name}")

    closure_block = "\n".join(f"    {name!r}," for name in closure)
    preload_src = PRELOAD_TEMPLATE.replace("__CLOSURE_LINES__", closure_block)

    pth = site_packages / "bpy.pth"
    preload_mod = site_packages / "_bpy_dll_preload.py"
    pth.write_text(PTH_CONTENT, encoding="ascii")
    preload_mod.write_text(preload_src, encoding="utf-8")

    print(f"wrote {pth}")
    print(f"wrote {preload_mod}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
