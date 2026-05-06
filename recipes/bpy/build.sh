#!/bin/bash
# Build bpy (Blender as a Python module) from source — for current Blender
# (5.x). For the 4.2 LTS line which needs additional compiler-strictness
# patches (TBB sed, freetype ftoption.h, etc.), see recipes/bpy_lts/.
#
# Steps:
#  1. Pull git-lfs objects (binary icon datafiles).
#  2. Fetch Blender's precompiled lib bundle (~5GB) via make_update.py.
#  3. Configure CMake with WITH_PYTHON_MODULE=ON pointed at conda's Python.
#  4. Build + install into a staging dir, then copy bpy/ into site-packages.
set -eo pipefail

# rattler-build auto-exports PY_VER (e.g. "3.12") and CPU_COUNT when python is
# in host requirements. Avoid `set -u` because some optional vars are unset.
PY_VER="${PY_VER:?PY_VER not set — is python in host requirements?}"
NPROC="${CPU_COUNT:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

echo "==> bpy build: python=$PY_VER  jobs=$NPROC  prefix=$PREFIX  src=$SRC_DIR"

cd "$SRC_DIR"

# rattler-build's `git:` source fetch does NOT pull git-lfs objects. Blender
# stores binary icon datafiles in LFS, so without this `datatoc_icon` fails
# during compile. rattler-build's `origin` is a local cache path so git-lfs
# can't auto-derive the endpoint — set it explicitly.
echo "==> Pulling git-lfs objects"
git lfs install --local
git config lfs.url https://projects.blender.org/blender/blender.git/info/lfs
git lfs pull

echo "==> Fetching Blender precompiled libs (this is the big one)"
# `make update` would `git pull --rebase` Blender source, but rattler-build
# checked out a detached HEAD at the tag. Skip the source update; only fetch
# the lib bundle + submodules. On Linux the bundle is opt-in via
# --use-linux-libraries; on macOS it's always fetched.
EXTRA_UPDATE_ARGS=""
if [[ "$(uname -s)" == "Linux" ]]; then
    EXTRA_UPDATE_ARGS="--use-linux-libraries"
fi
python ./build_files/utils/make_update.py --no-blender $EXTRA_UPDATE_ARGS

# Patch freetype config — Blender's lib bundle ships libfreetype.a alongside
# libbrotlicommon-static.a but the freetype headers don't define
# FT_CONFIG_OPTION_USE_BROTLI. Blender's check_freetype_for_brotli runs a
# header check and fails with "Freetype needs to be compiled with brotli
# support!". Define the macro so the check passes; the bundled .a has
# brotli code linked in. (Same issue exists across 4.2 and 5.1 lib bundles.)
LIB_PLATFORM=""
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) LIB_PLATFORM="linux_x64" ;;
    Darwin-arm64) LIB_PLATFORM="macos_arm64" ;;
    Darwin-x86_64) LIB_PLATFORM="macos_x64" ;;
esac
if [[ -n "$LIB_PLATFORM" ]]; then
    # Patch ftoption.h if present anywhere in the lib bundle.
    while IFS= read -r FT_OPTION_H; do
        if grep -q '^#define FT_CONFIG_OPTION_USE_BROTLI' "$FT_OPTION_H"; then
            continue
        fi
        echo "==> Patching freetype ftoption.h at $FT_OPTION_H"
        if grep -q 'FT_CONFIG_OPTION_USE_BROTLI' "$FT_OPTION_H"; then
            sed -i.bak 's|/\* *#define FT_CONFIG_OPTION_USE_BROTLI *\*/|#define FT_CONFIG_OPTION_USE_BROTLI|' "$FT_OPTION_H"
        else
            printf '\n#define FT_CONFIG_OPTION_USE_BROTLI\n' >> "$FT_OPTION_H"
        fi
    done < <(find "$SRC_DIR/lib/$LIB_PLATFORM" -name 'ftoption.h' 2>/dev/null)
fi
# Belt-and-suspenders: also disable the check at the CMake level. The bundle
# layout has shifted between Blender 4.2 and 5.x and the ftoption.h-find
# patch above sometimes finds nothing on 5.1's Linux bundle. Stub out the
# check function in platform_unix.cmake so it always passes — bundled
# libfreetype.a does have brotli code, just not exposed in the headers.
PLATFORM_UNIX_CMAKE="$SRC_DIR/build_files/cmake/platform/platform_unix.cmake"
if [[ -f "$PLATFORM_UNIX_CMAKE" ]]; then
    if grep -q 'Freetype needs to be compiled with brotli support' "$PLATFORM_UNIX_CMAKE"; then
        echo "==> Stubbing platform_unix.cmake's check_freetype_for_brotli to no-op"
        sed -i.bak 's|message(FATAL_ERROR "Freetype needs to be compiled with brotli support!")|message(WARNING "(bpy-conda) brotli check bypassed — bundled freetype is fine at runtime")|' "$PLATFORM_UNIX_CMAKE"
    fi
fi

INSTALL_DIR="$SRC_DIR/_bpy_install"
BUILD_DIR="$SRC_DIR/_bpy_build"
mkdir -p "$INSTALL_DIR" "$BUILD_DIR"

# Linux: rely on conda host packages for X11/EGL/GL headers (xorg-libx11,
# mesa-libegl-cos7-x86_64, etc. in recipe.yaml host). The earlier
# `-isystem /usr/include` workaround caused system glibc 2.39's malloc.h
# to win over conda sysroot 2.28's, breaking guardedalloc compile because
# `__attribute_alloc_align__` macros were undefined.

echo "==> CMake configure"
# macOS: pin SDK + archive tools.
#   * SDK: Blender's platform_apple.cmake auto-detects SDK via xcrun, which
#     picks up the host CommandLineTools SDK (could be very new). The conda
#     compiler activation sets CONDA_BUILD_SYSROOT to a known SDK; honor it.
#   * AR/RANLIB/LIBTOOL: without these, intermediate static libs end up in
#     GNU ar format which the macOS linker rejects with "unknown-unsupported
#     file format ( 0x21 0x3C ... )" (`!<arch>\n`).
OSX_FLAGS=()
if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ -n "${CONDA_BUILD_SYSROOT:-}" ]]; then
        OSX_FLAGS+=(
            "-DCMAKE_OSX_SYSROOT=$CONDA_BUILD_SYSROOT"
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}"
        )
    fi
    pick_tool() {
        local name="$1"; shift
        for cand in "$@"; do
            if [[ -x "$cand" ]]; then echo "$cand"; return; fi
        done
        echo "$name"
    }
    AR_BIN="$(pick_tool ar "${AR:-}" "$BUILD_PREFIX/bin/arm64-apple-darwin20.0.0-ar" "$BUILD_PREFIX/bin/llvm-ar")"
    RANLIB_BIN="$(pick_tool ranlib "${RANLIB:-}" "$BUILD_PREFIX/bin/arm64-apple-darwin20.0.0-ranlib" "$BUILD_PREFIX/bin/llvm-ranlib")"
    LIBTOOL_BIN="$(pick_tool libtool "${LIBTOOL:-}" "$BUILD_PREFIX/bin/arm64-apple-darwin20.0.0-libtool")"
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

if [ -d "$INSTALL_DIR/bpy" ]; then
    cp -R "$INSTALL_DIR/bpy" "$SITE_PACKAGES/"
elif [ -d "$INSTALL_DIR" ]; then
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
