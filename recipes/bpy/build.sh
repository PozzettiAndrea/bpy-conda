#!/bin/bash
# Build bpy (Blender as a Python module) from source.
#
# Steps:
#  1. Fetch Blender's precompiled library bundle (~5GB) via `make update`.
#  2. Configure CMake with WITH_PYTHON_MODULE=ON pointed at conda's Python.
#  3. Build + install into a staging dir, then copy bpy/ into site-packages.
#
# Notes:
#  - Blender's lib bundle is platform-specific: lib/linux_x64, lib/macos_arm64.
#    `make update` knows which one to fetch from `OS`/`uname`.
#  - We override PYTHON_VERSION/PYTHON_ROOT_DIR so Blender links against the
#    conda-host Python rather than the lib-bundle's bundled Python — that's
#    what lets us produce a 3.10/3.12/3.14 build off the same source.
#  - Disk-space and memory pressure on GH runners is real; the workflow adds
#    swap and runs the free-disk-space action before invoking this script.
set -eo pipefail

# rattler-build auto-exports PY_VER (e.g. "3.12") and CPU_COUNT when python is
# in host requirements. Avoid `set -u` because some optional vars are unset.
PY_VER="${PY_VER:?PY_VER not set — is python in host requirements?}"
NPROC="${CPU_COUNT:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

echo "==> bpy build: python=$PY_VER  jobs=$NPROC  prefix=$PREFIX  src=$SRC_DIR"

cd "$SRC_DIR"

# rattler-build's `git:` source fetch does NOT pull git-lfs objects. Blender
# stores binary icon datafiles (release/datafiles/blender_icons*/) in LFS, so
# without this the DAT files are pointer text files and `datatoc_icon` fails
# with "failed to read pixels" / "dir has no icons" during compile.
#
# rattler-build's `origin` remote points at a local bare-clone cache (not a
# real URL), so git-lfs can't auto-derive the endpoint. Set it explicitly to
# Blender's Gitea LFS endpoint.
echo "==> Pulling git-lfs objects"
git lfs install --local
git config lfs.url https://projects.blender.org/blender/blender.git/info/lfs
git lfs pull

echo "==> Fetching Blender precompiled libs (this is the big one)"
# `make update` would also `git pull --rebase` Blender source, but rattler-build
# checked out a detached HEAD at the tag — no upstream to pull from. Skip the
# source update and only fetch the lib bundle + submodules via the underlying
# make_update.py script.
#
# On Linux, the precompiled lib bundle is opt-in: make_update.py defaults to
# "use system packages" and skips lib/linux_x64 unless --use-linux-libraries
# is passed. On macOS the bundle is always fetched.
EXTRA_UPDATE_ARGS=""
if [[ "$(uname -s)" == "Linux" ]]; then
    EXTRA_UPDATE_ARGS="--use-linux-libraries"
fi
python ./build_files/utils/make_update.py --no-blender $EXTRA_UPDATE_ARGS

# Patch TBB header — Blender's bundled TBB has
#   static const kind_type binding_completed = kind_type(bound+1);
# Clang 22+ rejects this with a hard C++ error: the resulting value (2) is
# outside the valid range [0, 1] for the kind_type enum. There's no warning
# flag to suppress it; we have to actually change the type. Use `int`
# instead — comparisons with kind_type values still work via implicit
# conversion, and TBB only uses `binding_completed` as a sentinel.
LIB_PLATFORM=""
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) LIB_PLATFORM="linux_x64" ;;
    Darwin-arm64) LIB_PLATFORM="macos_arm64" ;;
    Darwin-x86_64) LIB_PLATFORM="macos_x64" ;;
esac
TBB_TASK_H="$SRC_DIR/lib/$LIB_PLATFORM/tbb/include/tbb/task.h"
if [[ -n "$LIB_PLATFORM" && -f "$TBB_TASK_H" ]]; then
    echo "==> Patching TBB header for clang 22 strictness"
    # All `static const kind_type X = kind_type(Y+1);` declarations produce
    # values outside the kind_type enum range. Rewrite each to int.
    python - "$TBB_TASK_H" <<'PYEOF'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
new = re.sub(
    r'static const kind_type (\w+)\s*=\s*kind_type\((\w+)\s*\+\s*1\);',
    r'static const int \1 = static_cast<int>(\2) + 1;',
    s,
)
# Also undo the previous half-patched form if present.
new = re.sub(
    r'static const kind_type (\w+)\s*=\s*kind_type\(int\((\w+)\)\s*\+\s*1\);',
    r'static const int \1 = static_cast<int>(\2) + 1;',
    new,
)
p.write_text(new)
print(f"==> Patched {sum(1 for _ in re.finditer(r'static const int \\w+ = static_cast<int>', new))} kind_type sentinels")
PYEOF
fi

INSTALL_DIR="$SRC_DIR/_bpy_install"
BUILD_DIR="$SRC_DIR/_bpy_build"
mkdir -p "$INSTALL_DIR" "$BUILD_DIR"

# On Linux, conda's compiler is sandboxed to its own sysroot — system
# /usr/include is not searched by default. The workflow apt-installs
# libegl-dev / libgl-dev / libx11-dev there. Add /usr/include as a
# system include path so the compiler finds EGL/eglplatform.h etc.
# without us having to vendor or copy headers around.
if [[ "$(uname -s)" == "Linux" ]]; then
    export CXXFLAGS="${CXXFLAGS:-} -isystem /usr/include"
    export CFLAGS="${CFLAGS:-} -isystem /usr/include"
fi

# On macOS, suppress clang 22's hard error on TBB's
# `kind_type binding_completed = kind_type(bound+1)` — the enum-overflow is
# real, but TBB upstream considers it benign; sed-patching to int() doesn't
# help because clang checks the final value vs the enum range.
if [[ "$(uname -s)" == "Darwin" ]]; then
    export CXXFLAGS="${CXXFLAGS:-} -Wno-error=enum-constexpr-conversion -Wno-enum-constexpr-conversion"
    export CFLAGS="${CFLAGS:-} -Wno-error=enum-constexpr-conversion -Wno-enum-constexpr-conversion"
fi

echo "==> CMake configure"
# On macOS, force CMake to use conda-forge's SDK rather than letting Blender's
# platform_apple.cmake auto-detect via xcrun (which picks up the host CLT SDK
# — that's how SDK 26 sneaks in when host machines have it). The conda
# compiler activation sets CONDA_BUILD_SYSROOT to e.g. .../MacOSX11.0.sdk.
OSX_FLAGS=()
if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ -n "${CONDA_BUILD_SYSROOT:-}" ]]; then
        OSX_FLAGS+=(
            "-DCMAKE_OSX_SYSROOT=$CONDA_BUILD_SYSROOT"
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}"
        )
    fi
    # Pin archive tools to conda-forge cctools wrappers — without this, some
    # intermediate static libs end up in GNU ar format and the macOS linker
    # rejects them with "unknown-unsupported file format ( 0x21 0x3C ... )".
    # Pick the first that exists; HOST/AR may be unset depending on activation.
    pick_tool() {
        local name="$1"; shift
        for cand in "$@"; do
            if [[ -x "$cand" ]]; then echo "$cand"; return; fi
        done
        # Last resort: rely on PATH; CMake will fail explicitly if missing.
        echo "$name"
    }
    AR_BIN="$(pick_tool ar \
        "${AR:-}" \
        "$BUILD_PREFIX/bin/arm64-apple-darwin20.0.0-ar" \
        "$BUILD_PREFIX/bin/llvm-ar")"
    RANLIB_BIN="$(pick_tool ranlib \
        "${RANLIB:-}" \
        "$BUILD_PREFIX/bin/arm64-apple-darwin20.0.0-ranlib" \
        "$BUILD_PREFIX/bin/llvm-ranlib")"
    LIBTOOL_BIN="$(pick_tool libtool \
        "${LIBTOOL:-}" \
        "$BUILD_PREFIX/bin/arm64-apple-darwin20.0.0-libtool")"
    echo "==> AR=$AR_BIN  RANLIB=$RANLIB_BIN  LIBTOOL=$LIBTOOL_BIN"
    OSX_FLAGS+=(
        "-DCMAKE_AR=$AR_BIN"
        "-DCMAKE_RANLIB=$RANLIB_BIN"
        "-DCMAKE_LIBTOOL=$LIBTOOL_BIN"
    )
fi

cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DWITH_PYTHON_MODULE=ON \
    -DWITH_PYTHON_INSTALL=OFF \
    -DWITH_INSTALL_PORTABLE=ON \
    -DWITH_AUDASPACE=ON \
    -DWITH_INSTALL_COPYRIGHT=ON \
    -DWITH_XR_OPENXR=OFF \
    -DPYTHON_VERSION="$PY_VER" \
    -DPYTHON_ROOT_DIR="$PREFIX" \
    -DPYTHON_EXECUTABLE="$PREFIX/bin/python$PY_VER" \
    -DPYTHON_INCLUDE_DIR="$PREFIX/include/python${PY_VER}" \
    -DPYTHON_LIBRARY="$PREFIX/lib/libpython${PY_VER}.so" \
    "${OSX_FLAGS[@]}"

echo "==> CMake build + install"
cmake --build "$BUILD_DIR" --target install -j"$NPROC"

echo "==> Stage bpy module into \$PREFIX/lib/python$PY_VER/site-packages/"
SITE_PACKAGES="$PREFIX/lib/python${PY_VER}/site-packages"
mkdir -p "$SITE_PACKAGES"

# WITH_PYTHON_MODULE + WITH_INSTALL_PORTABLE places the importable module under
# a `bpy/` directory plus a `bpy.so`/`bpy.dylib` loader and the matching
# Blender resources (`<version>/scripts`, etc.). Layout post-install is
# typically: $INSTALL_DIR/bpy/* (the python package).
if [ -d "$INSTALL_DIR/bpy" ]; then
    cp -R "$INSTALL_DIR/bpy" "$SITE_PACKAGES/"
elif [ -d "$INSTALL_DIR" ]; then
    # Fallback: locate bpy via find — covers cases where the install layout
    # changes between Blender versions.
    BPY_PATH="$(find "$INSTALL_DIR" -maxdepth 3 -type d -name 'bpy' | head -1)"
    if [ -z "$BPY_PATH" ]; then
        echo "ERROR: could not locate built bpy/ directory under $INSTALL_DIR"
        ls -R "$INSTALL_DIR" | head -200
        exit 1
    fi
    cp -R "$BPY_PATH" "$SITE_PACKAGES/"
fi

echo "==> Done. Contents of site-packages/bpy:"
ls -la "$SITE_PACKAGES/bpy" | head -20
