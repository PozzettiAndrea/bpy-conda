@echo off
REM Build bpy (Blender as a Python module) from source on Windows.
REM
REM Mirrors recipes/bpy/build.sh: fetch lib bundle via `make.bat update`,
REM configure CMake with WITH_PYTHON_MODULE=ON pointed at conda's Python,
REM build+install, then stage bpy\ into Library\Lib\site-packages\.
setlocal enabledelayedexpansion

REM Force Python's stdio to UTF-8 — see recipes/bpy/build.bat for rationale.
set "PYTHONIOENCODING=utf-8"
set "PYTHONUTF8=1"

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
REM Use Python (binary-safe) instead of PowerShell which defaults to UTF-16
REM and was corrupting the file encoding so the include never took effect.
echo ==^> Patching cycles profiling.cpp for MSVC 14.4x chrono visibility
python -c "import pathlib; p = pathlib.Path(r'%SRC_DIR%\intern\cycles\util\profiling.cpp'); s = p.read_text(encoding='utf-8'); print('already patched') if '<chrono>' in s.splitlines()[0] else (p.write_text('#include <chrono>\n' + s, encoding='utf-8'), print('patched'))"

set "INSTALL_DIR=%SRC_DIR%\_bpy_install"
set "BUILD_DIR=%SRC_DIR%\_bpy_build"
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

REM Patch platform_win32.cmake to respect external -DPYTHON_* flags
REM — see recipes/bpy_lts_3_6/build.bat + scripts/patch_blender_win32_python.py.
echo ==^> Patching platform_win32.cmake to respect external -DPYTHON_* flags
python "%RECIPE_DIR%\..\..\scripts\patch_blender_win32_python.py" "%SRC_DIR%"

REM Patch mathutils_noise.cc to #include <ctime>. CPython 3.13+ stopped
REM transitively re-exporting <time.h> via <Python.h>, so the existing
REM time(nullptr) call in mathutils_noise.cc fails MSVC compile with
REM "error C3861: 'time': identifier not found". Idempotent.
echo ==^> Patching mathutils_noise.cc for CPython 3.13+ header hygiene
python "%RECIPE_DIR%\..\..\scripts\patch_blender_mathutils_noise.py" "%SRC_DIR%"

REM Stage numpy headers into %PREFIX%\include — see recipes/bpy/build.bat
REM for the full rationale. 4.2 LTS doesn't have the audaspace binding
REM that needs this, but the staging is idempotent + harmless and keeps
REM the three recipes structurally aligned.
echo ==^> Staging numpy headers into %PREFIX%\include\numpy
for /f "delims=" %%i in ('python -c "import numpy; print(numpy.get_include())"') do set "NUMPY_INC=%%i"
echo   numpy.get_include^(^) -^> %NUMPY_INC%
if exist "%NUMPY_INC%\numpy" (
    if not exist "%PREFIX%\include\numpy" (
        xcopy /E /I /Y /Q "%NUMPY_INC%\numpy" "%PREFIX%\include\numpy" >nul && echo   staged numpy headers
    ) else (
        echo   %PREFIX%\include\numpy already exists, skipping
    )
)

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

REM DLL backstop with skip-list — see recipes/bpy_lts_3_6/build.bat for rationale.
REM Skip python*/vcruntime*/msvcp*/ucrtbase*/vcomp*/libomp*/libiomp5* — env runtimes.
REM TBB / embree / etc. are NOT skipped: the mangler step below renames them
REM into a private "bpy_*" namespace; we want all bundled DLLs present first.
echo ==^> DLL backstop: copying missing bundled DLLs into bpy\ (skip-list applied)
for /R "%SRC_DIR%\lib\windows_x64" %%F in (*.dll) do (
    if not exist "%SITE_PACKAGES%\bpy\%%~nxF" (
        echo %%~nxF | findstr /B /I /R "^python[0-9] ^vcruntime ^msvcp ^ucrtbase ^vcomp ^libomp ^libiomp5" >nul && (
            echo   skip    %%~nxF
        ) || (
            copy /Y "%%F" "%SITE_PACKAGES%\bpy\" >nul && echo   copied %%~nxF
        )
    )
)
echo ==^> Removing stray python*.dll from bpy\ (off-spec heap-corruption fix)
del /F /Q "%SITE_PACKAGES%\bpy\python*.dll" 2>nul

echo ==^> Diagnostic: python*.dll inside bpy\ ^(should be empty^)
dir /B "%SITE_PACKAGES%\bpy\python*.dll" 2>nul && echo   UNEXPECTED || echo   none

REM Strip bundled OpenMP runtime — see recipes/bpy/build.bat for rationale.
echo ==^> Stripping bundled OpenMP runtimes from bpy\
del /F /Q "%SITE_PACKAGES%\bpy\vcomp*.dll" 2>nul
del /F /Q "%SITE_PACKAGES%\bpy\libomp.dll" 2>nul
del /F /Q "%SITE_PACKAGES%\bpy\libiomp5md.dll" 2>nul

REM Strip bundled tbbmalloc_proxy + ship TBB_MALLOC_DISABLE_REPLACEMENT
REM activate.d script. See recipes/bpy_lts_3_6/build.bat for full rationale.
REM (Runs BEFORE the mangler so the mangler doesn't have to handle this DLL.)
echo ==^> Stripping bundled tbbmalloc_proxy from bpy\ (heap-corruption fix)
del /F /Q "%SITE_PACKAGES%\bpy\tbbmalloc_proxy*.dll" 2>nul

REM Mangle every remaining bundled DLL in bpy\ into a "bpy_*" private
REM namespace — see recipes/bpy/build.bat for the full rationale.
echo ==^> Mangling bpy/ DLLs to bpy_ private namespace (loader-race fix)
python "%RECIPE_DIR%\..\..\scripts\mangle_bpy_dlls.py" "%SITE_PACKAGES%\bpy"
if errorlevel 1 exit /b 1

echo ==^> Installing TBB_MALLOC_DISABLE_REPLACEMENT activate.d script
set "ACT_DIR=%PREFIX%\etc\conda\activate.d"
set "DEACT_DIR=%PREFIX%\etc\conda\deactivate.d"
if not exist "%ACT_DIR%" mkdir "%ACT_DIR%"
if not exist "%DEACT_DIR%" mkdir "%DEACT_DIR%"
python -c "import os, pathlib; p = pathlib.Path(os.environ['ACT_DIR']) / 'bpy-tbb-malloc-disable.bat'; p.write_text('@echo off\r\nset \"_BPY_PRIOR_TBB_MALLOC_DISABLE_REPLACEMENT=%TBB_MALLOC_DISABLE_REPLACEMENT%\"\r\nset \"TBB_MALLOC_DISABLE_REPLACEMENT=1\"\r\n'); print('wrote', p)"
python -c "import os, pathlib; p = pathlib.Path(os.environ['DEACT_DIR']) / 'bpy-tbb-malloc-disable.bat'; p.write_text('@echo off\r\nif defined _BPY_PRIOR_TBB_MALLOC_DISABLE_REPLACEMENT (set \"TBB_MALLOC_DISABLE_REPLACEMENT=%_BPY_PRIOR_TBB_MALLOC_DISABLE_REPLACEMENT%\") else (set \"TBB_MALLOC_DISABLE_REPLACEMENT=\")\r\nset \"_BPY_PRIOR_TBB_MALLOC_DISABLE_REPLACEMENT=\"\r\n'); print('wrote', p)"

echo ==^> Done.
dir "%SITE_PACKAGES%\bpy"
