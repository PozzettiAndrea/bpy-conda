@echo off
REM Build bpy (Blender as a Python module) from source on Windows.
REM
REM Mirrors recipes/bpy/build.sh: fetch lib bundle via `make.bat update`,
REM configure CMake with WITH_PYTHON_MODULE=ON pointed at conda's Python,
REM build+install, then stage bpy\ into Library\Lib\site-packages\.
setlocal enabledelayedexpansion

REM rattler-build auto-sets PY_VER (e.g. "3.12") when python is in host reqs.
if "%PY_VER%"=="" (
    echo ERROR: PY_VER not set & exit /b 1
)

set "PY_NODOT=%PY_VER:.=%"
set "NPROC=%CPU_COUNT%"
if "%NPROC%"=="" set "NPROC=%NUMBER_OF_PROCESSORS%"

echo ==^> bpy build: python=%PY_VER% jobs=%NPROC% prefix=%PREFIX% src=%SRC_DIR%

cd /d "%SRC_DIR%"

REM rattler-build's git: source fetch doesn't pull LFS objects; Blender stores
REM icon datafiles in LFS so we need to materialize them before make_update.
REM Origin is a local cache path so set the LFS URL explicitly.
echo ==^> Pulling git-lfs objects
call git lfs install --local
call git config lfs.url https://projects.blender.org/blender/blender.git/info/lfs
call git lfs pull

echo ==^> Fetching Blender precompiled libs
REM Skip git pull (rattler-build uses detached HEAD); only fetch libs/submodules.
python build_files\utils\make_update.py --no-blender
if errorlevel 1 exit /b 1

REM Patch profiling.cpp — MSVC 14.4x no longer transitively includes <chrono>.
REM Use Python (binary-safe) instead of PowerShell which defaults to UTF-16.
echo ==^> Patching cycles profiling.cpp for MSVC 14.4x chrono visibility
python -c "import pathlib; p = pathlib.Path(r'%SRC_DIR%\intern\cycles\util\profiling.cpp'); s = p.read_text(encoding='utf-8'); print('already patched') if '<chrono>' in s.splitlines()[0] else (p.write_text('#include <chrono>\n' + s, encoding='utf-8'), print('patched'))"

set "INSTALL_DIR=%SRC_DIR%\_bpy_install"
set "BUILD_DIR=%SRC_DIR%\_bpy_build"
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

REM MSVC 14.44 added warning C5287 "operands are different enum types" which
REM Blender 3.6's BKE_customdata.h triggers (CD_FAKE enum vs eCustomDataType).
REM Blender uses /WX so warning → error. Disable just C5287.
set "CL=/wd5287 %CL%"

echo ==^> CMake configure
REM Use Blender's official bpy_module.cmake preset — see recipes/bpy/build.bat
REM for rationale (WITH_TBB_MALLOC_PROXY=OFF, WITH_WINDOWS_BUNDLE_CRT=OFF, ...).
cmake -C "%SRC_DIR%\build_files\cmake\config\bpy_module.cmake" ^
    -S "%SRC_DIR%" -B "%BUILD_DIR%" -G Ninja ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_INSTALL_PREFIX="%INSTALL_DIR%" ^
    -DWITH_INSTALL_PORTABLE=ON ^
    -DWITH_USD=OFF ^
    -DWITH_INSTALL_COPYRIGHT=ON ^
    -DPYTHON_VERSION="%PY_VER%" ^
    -DPYTHON_ROOT_DIR="%PREFIX%" ^
    -DPYTHON_EXECUTABLE="%PREFIX%\python.exe" ^
    -DPYTHON_INCLUDE_DIR="%PREFIX%\include" ^
    -DPYTHON_LIBRARY="%PREFIX%\libs\python%PY_NODOT%.lib"
if errorlevel 1 exit /b 1

echo ==^> CMake build + install
cmake --build "%BUILD_DIR%" --target install -j%NPROC%
if errorlevel 1 exit /b 1

echo ==^> Stage bpy module into %PREFIX%\Lib\site-packages
set "SITE_PACKAGES=%PREFIX%\Lib\site-packages"
if not exist "%SITE_PACKAGES%" mkdir "%SITE_PACKAGES%"

if exist "%INSTALL_DIR%\bpy" (
    xcopy /E /I /Y "%INSTALL_DIR%\bpy" "%SITE_PACKAGES%\bpy"
) else (
    echo ERROR: %INSTALL_DIR%\bpy not found, dumping install dir for diagnosis:
    dir /S /B "%INSTALL_DIR%" | more /e +200
    exit /b 1
)

REM Strip bundled OpenMP runtime — see recipes/bpy/build.bat for rationale.
echo ==^> Stripping bundled OpenMP runtimes from bpy\
del /F /Q "%SITE_PACKAGES%\bpy\vcomp*.dll" 2>nul
del /F /Q "%SITE_PACKAGES%\bpy\libomp.dll" 2>nul
del /F /Q "%SITE_PACKAGES%\bpy\libiomp5md.dll" 2>nul

echo ==^> Done.
dir "%SITE_PACKAGES%\bpy"
