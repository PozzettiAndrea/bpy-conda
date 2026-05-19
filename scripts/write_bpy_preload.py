"""
Write `bpy.pth` and `_bpy_dll_preload.py` into <site_packages>.

Background: Windows' DLL loader doesn't propagate
`LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` through deep transitive
dependency chains. When `import bpy` triggers `LoadLibraryEx` on
`bpy/__init__.pyd`, only its IMMEDIATE deps get `bpy/` prepended
to their search path. Deeper transitive deps (e.g., `Zmbree4.dll`
needs `Zycl8.dll` needs `Zr_win_proxy_loader.dll`) are resolved
against the default DLL search path — which does NOT include `bpy/`.

The fix: at Python startup (before user code runs), explicitly
`LoadLibrary` every Z-prefixed DLL in `bpy/`. They go into the
process's module cache. When `bpy/__init__.pyd` later loads, every
IAT entry resolves to an already-loaded module via Windows' basename
cache — no search-path resolution needed for transitive deps.

The .pth file's `import` line is processed by site.py at startup,
before any user `import`. It imports `_bpy_dll_preload` which runs
the preload logic at module-import time.

Usage:
    python scripts/write_bpy_preload.py <site_packages_dir>
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

PTH_CONTENT = "import _bpy_dll_preload\n"

PRELOAD_MODULE = r'''"""Preload bpy/'s mangled DLLs into the process at site.py time.

Required because Windows' DLL loader doesn't propagate the parent
PE's DLL search dirs through deep transitive dependency chains. By
explicitly LoadLibrary-ing every Z-prefixed DLL in bpy/ at Python
startup, we ensure they're in the process basename cache when
bpy.pyd's IAT is resolved later via `import bpy`.

Installed by bpy-conda's build.bat. See scripts/write_bpy_preload.py.
"""
import os
import site
import ctypes


def _preload_bpy_dlls() -> None:
    for sp in site.getsitepackages():
        bpy_dir = os.path.join(sp, "bpy")
        if not os.path.isdir(bpy_dir):
            continue
        os.add_dll_directory(bpy_dir)
        for name in sorted(os.listdir(bpy_dir)):
            if name.lower().endswith(".dll"):
                try:
                    ctypes.WinDLL(os.path.join(bpy_dir, name))
                except OSError:
                    # GPU/driver-runtime DLLs (Zmbree4, Zycl8 etc.) may
                    # fail without Intel oneAPI / AMD HIP runtime
                    # installed. That's fine — they're lazy-loaded
                    # paths used only for GPU rendering. bpy itself
                    # imports cleanly without them.
                    pass
        return  # only process the first site-packages that has bpy/


_preload_bpy_dlls()
'''


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: write_bpy_preload.py <site_packages>", file=sys.stderr)
        return 2

    site_packages = Path(sys.argv[1]).resolve()
    if not site_packages.is_dir():
        print(f"not a directory: {site_packages}", file=sys.stderr)
        return 1

    pth = site_packages / "bpy.pth"
    preload_mod = site_packages / "_bpy_dll_preload.py"

    pth.write_text(PTH_CONTENT, encoding="ascii")
    preload_mod.write_text(PRELOAD_MODULE, encoding="utf-8")

    print(f"wrote {pth}")
    print(f"wrote {preload_mod}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
