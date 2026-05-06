"""Smoke test for `bpy` Python module — runs in rattler-build's recipe test
phase (a fresh conda env with only python + this package's run deps).

Inspired by Blender's `tests/python/bl_pyapi_*.py` suite; adapted to NOT
require Blender's CLI argv (`-b`, `--factory-startup`). Each section is a
separate try/except so we surface every failure, not just the first.

Run with: python smoke_api.py
"""
from __future__ import annotations
import sys


FAILS: list[str] = []


def check(label: str, fn) -> None:
    try:
        fn()
        print(f"  ok    {label}")
    except Exception as e:
        FAILS.append(f"{label}: {type(e).__name__}: {e}")
        print(f"  FAIL  {label}: {type(e).__name__}: {e}")


def main() -> int:
    print("== smoke_api.py ==")

    # 1. Module loads. If a DSO/DLL is missing, this throws and everything else
    # is moot.
    check("import bpy", lambda: __import__("bpy"))
    if any(f.startswith("import bpy:") for f in FAILS):
        print("FAIL: cannot proceed without bpy")
        return 1

    import bpy

    # 2. bpy.app namespace — version, build info. Cheap; doesn't allocate
    # OpenGL state. Mirrors bl_pyapi_bpy_app.py minus the cachedir test.
    check("bpy.app.version is 3-tuple", lambda: (
        isinstance(bpy.app.version, tuple) and len(bpy.app.version) == 3
        and all(isinstance(x, int) for x in bpy.app.version)
    ) or (_ for _ in ()).throw(AssertionError(f"got {bpy.app.version!r}")))
    check("bpy.app.version_string non-empty", lambda: (
        isinstance(bpy.app.version_string, str) and len(bpy.app.version_string) > 0
    ) or (_ for _ in ()).throw(AssertionError("empty")))

    # 3. mathutils — pure-Python-callable C extension; no Blender state needed.
    # Inspired by bl_pyapi_mathutils.py.
    def _mathutils():
        from mathutils import Vector, Matrix, Quaternion
        v = Vector((3.0, 4.0, 0.0))
        assert abs(v.length - 5.0) < 1e-9, f"length={v.length}"
        m = Matrix.Identity(4)
        assert (m @ v.to_4d()).to_3d() == v, "identity @ v != v"
        q = Quaternion()
        assert abs(q.angle) < 1e-9, f"identity-quaternion angle={q.angle}"
    check("mathutils Vector/Matrix/Quaternion roundtrip", _mathutils)

    # 4. idprop — IDProperty roundtrip on a scene-like container.
    # Inspired by bl_pyapi_idprop.py. Requires homefile state for a scene.
    def _idprop():
        # `read_homefile(use_factory_startup=True)` initializes a default
        # scene without touching the user's preferences. Headless-safe.
        bpy.ops.wm.read_homefile(use_factory_startup=True)
        s = bpy.context.scene
        assert s is not None, "scene is None after read_homefile"
        s["smoke_test_key"] = 42
        assert s["smoke_test_key"] == 42
        del s["smoke_test_key"]
    check("idprop scene roundtrip via read_homefile", _idprop)

    # 5. bmesh — geometry creation API. Inspired by bl_pyapi_bmesh.py.
    def _bmesh():
        import bmesh
        bm = bmesh.new()
        v0 = bm.verts.new((0.0, 0.0, 0.0))
        v1 = bm.verts.new((1.0, 0.0, 0.0))
        v2 = bm.verts.new((1.0, 1.0, 0.0))
        bm.faces.new((v0, v1, v2))
        assert len(bm.verts) == 3 and len(bm.faces) == 1
        bm.free()
    check("bmesh new/verts/faces", _bmesh)

    print(f"== {len(FAILS)} failure(s) ==")
    return 0 if not FAILS else 1


if __name__ == "__main__":
    sys.exit(main())
