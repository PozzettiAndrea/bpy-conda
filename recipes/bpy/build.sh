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

INSTALL_DIR="$SRC_DIR/_bpy_install"
BUILD_DIR="$SRC_DIR/_bpy_build"
mkdir -p "$INSTALL_DIR" "$BUILD_DIR"

echo "==> CMake configure"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DWITH_PYTHON_MODULE=ON \
    -DWITH_PYTHON_INSTALL=OFF \
    -DWITH_INSTALL_PORTABLE=ON \
    -DWITH_AUDASPACE=ON \
    -DWITH_INSTALL_COPYRIGHT=ON \
    -DPYTHON_VERSION="$PY_VER" \
    -DPYTHON_ROOT_DIR="$PREFIX" \
    -DPYTHON_EXECUTABLE="$PREFIX/bin/python$PY_VER" \
    -DPYTHON_INCLUDE_DIR="$PREFIX/include/python${PY_VER}" \
    -DPYTHON_LIBRARY="$PREFIX/lib/libpython${PY_VER}.so"

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
