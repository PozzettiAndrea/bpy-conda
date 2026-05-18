@echo off
REM Build bpy (Blender as a Python module) from source on Windows.
REM
REM Mirrors recipes/bpy/build.sh: fetch lib bundle via `make.bat update`,
REM configure CMake with WITH_PYTHON_MODULE=ON pointed at conda's Python,
REM build+install, then stage bpy\ into Library\Lib\site-packages\.
setlocal enabledelayedexpansion

REM Force Python's stdio to UTF-8 — see recipes/bpy/build.bat for rationale.
REM This is especially load-bearing for 3.6 LTS where mathutils_noise.cc
REM doesn't exist (Blender migrated mathutils to C++ in 4.0), so the patch
REM script takes the `WARN: ... not found -- skipping` branch. Without
REM PYTHONIOENCODING the earlier em-dash version of that warning emitted
REM a stray CP-1252 byte that permanently silenced rattler-build's live
REM log stream for the rest of the (multi-hour) build.
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

REM Patch Blender's platform_win32.cmake to respect externally-supplied
REM -DPYTHON_VERSION / -DPYTHON_LIBRARY / -DPYTHON_INCLUDE_DIR /
REM -DPYTHON_EXECUTABLE flags. Stock Blender unconditionally overrides
REM these to the bundle's pinned CPython (3.10 for 3.6 LTS), forcing
REM bpy.pyd to link against the wrong python.dll on off-spec combos
REM (3.6+py3.11+, 4.2+py3.12+, 5.1+py3.14). See the patch script for
REM the full rationale.
echo ==^> Patching platform_win32.cmake to respect external -DPYTHON_* flags
python "%RECIPE_DIR%\..\..\scripts\patch_blender_win32_python.py" "%SRC_DIR%"

REM Patch mathutils_noise.cc to #include <ctime>. CPython 3.13+ stopped
REM transitively re-exporting <time.h> via <Python.h>, so the existing
REM time(nullptr) call in mathutils_noise.cc fails MSVC compile with
REM "error C3861: 'time': identifier not found". Idempotent.
echo ==^> Patching mathutils_noise.cc for CPython 3.13+ header hygiene
python "%RECIPE_DIR%\..\..\scripts\patch_blender_mathutils_noise.py" "%SRC_DIR%"

REM Stage numpy headers into %PREFIX%\include — see recipes/bpy/build.bat
REM for the full rationale. 3.6 LTS doesn't have the audaspace binding
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

REM DLL backstop: Blender's Windows lib bundle ships many DLLs that
REM `make_install` doesn't always copy into bpy\. Walk lib\windows_x64
REM and copy missing ones — but EXCLUDE filenames that would conflict
REM with the conda env's CRT/python/CRYPT/SQL runtimes:
REM
REM   python*.dll        — the bundle ships the Python it was built
REM                        against (cp310 for 3.6, cp311 for 4.2,
REM                        cp313 for 5.1). Copying that into bpy\ on
REM                        an off-spec env (e.g. 4.2 + py3.12) loads
REM                        TWO libpython instances → cross-runtime
REM                        PyMem_Malloc/PyObject_Free →
REM                        STATUS_HEAP_CORRUPTION (0xC0000374).
REM   vcruntime*, msvcp*, ucrtbase*  — env's vc14_runtime owns these.
REM   vcomp*, libomp*, libiomp5*     — already stripped below.
REM   (TBB / embree / etc. are NOT skipped: the mangler step renames them
REM   into a private "bpy_*" namespace; we want all bundled DLLs present
REM   so the mangler sees + renames them in one pass.)
REM
REM Without this skip-list, official combos pass (bundle's python ==
REM env's python, no conflict) but off-spec combos crash deterministically.
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
REM Belt-and-suspenders: explicitly remove any python*.dll that Blender's
REM own install rules may have placed in bpy\ before our backstop ran.
REM This is the smoking-gun check Expert B identified (two libpython
REM coexisting → STATUS_HEAP_CORRUPTION on off-spec combos).
echo ==^> Removing stray python*.dll from bpy\ (off-spec heap-corruption fix)
del /F /Q "%SITE_PACKAGES%\bpy\python*.dll" 2>nul

REM Diagnostic — confirm bpy\ has no conflicting python runtime, log
REM bpy.pyd's actual python import.
echo ==^> Diagnostic: python*.dll and bpy.pyd's import table
dir /B "%SITE_PACKAGES%\bpy\python*.dll" 2>nul && echo   ^(unexpected — should be empty^) || echo   none ^(good^)
where dumpbin >nul 2>&1 && (
    for %%P in ("%SITE_PACKAGES%\bpy\bpy.pyd" "%SITE_PACKAGES%\bpy\__init__.pyd") do (
        if exist %%P dumpbin /DEPENDENTS %%P 2>nul | findstr /R /I "python[0-9]*\.dll" 2>nul
    )
)

REM Strip bundled OpenMP runtime — see recipes/bpy/build.bat for rationale.
echo ==^> Stripping bundled OpenMP runtimes from bpy\
del /F /Q "%SITE_PACKAGES%\bpy\vcomp*.dll" 2>nul
del /F /Q "%SITE_PACKAGES%\bpy\libomp.dll" 2>nul
del /F /Q "%SITE_PACKAGES%\bpy\libiomp5md.dll" 2>nul

REM Strip bundled tbbmalloc_proxy. Windows counterpart of bpy_module.cmake's
REM `WITH_TBB_MALLOC_PROXY=OFF`: that flag disables LINK-time use, but tbb.dll
REM in the same directory auto-loads tbbmalloc_proxy.dll via the SxS / module-
REM init path, which then hijacks malloc/free across the whole process and
REM crashes with STATUS_HEAP_CORRUPTION (0xC0000374) when Python's own
REM allocator frees memory through tbbmalloc's free. Same bug as Linux's
REM munmap_chunk(): invalid pointer, just a different abort path.
echo ==^> Stripping bundled tbbmalloc_proxy from bpy\ (heap-corruption fix)
del /F /Q "%SITE_PACKAGES%\bpy\tbbmalloc_proxy*.dll" 2>nul

REM Mangle every remaining bundled DLL in bpy\ into a "bpy_*" private
REM namespace and rewrite every .pyd/.dll's PE import table to match.
REM This is the proper fix for the Windows loader race against torch /
REM embreex / anything that ships its own tbb12.dll / embree4.dll —
REM Windows' basename-already-loaded cache can't collide on a DLL name
REM nobody else uses. Same technique delvewheel uses for wheels.
REM
REM The earlier "strip tbb*.dll + run-dep on conda-forge tbb" approach
REM fixed nothing: conda-forge's tbb provides tbb12.dll, but bpy.pyd's
REM IAT literally names tbb.dll (for 3.6 / 4.2 LTS classic TBB 2020),
REM and tbb12.dll on the env path is a different ABI vintage anyway.
echo ==^> Mangling bpy/ DLLs to bpy_ private namespace (loader-race fix)
python "%RECIPE_DIR%\..\..\scripts\mangle_bpy_dlls.py" "%SITE_PACKAGES%\bpy"
if errorlevel 1 exit /b 1

REM Stripping isn't sufficient: conda-forge's `tbb` package (transitively
REM pulled in via vc14_runtime) ships its own `Library\bin\tbbmalloc_proxy.dll`
REM in the env, and Windows DLL search picks it up at runtime. Use the
REM Blender-team-recommended workaround (T88813, #148601): set
REM `TBB_MALLOC_DISABLE_REPLACEMENT=1` so the proxy refuses to hijack the
REM CRT allocator at module init. Ship it as an activate.d script so the
REM env-var is set whenever the user `conda activate`s an env with bpy.
REM (Conda activates run *.bat from Library\etc\conda\activate.d on Windows.)
echo ==^> Installing TBB_MALLOC_DISABLE_REPLACEMENT activate.d script
set "ACT_DIR=%PREFIX%\etc\conda\activate.d"
set "DEACT_DIR=%PREFIX%\etc\conda\deactivate.d"
if not exist "%ACT_DIR%" mkdir "%ACT_DIR%"
if not exist "%DEACT_DIR%" mkdir "%DEACT_DIR%"
REM Use Python (in the build env) to write the activate.d / deactivate.d
REM scripts. cmd.exe's `> file (block)` syntax barfs status 255 on the
REM `%%` escapes we'd need for batch variable references.
python -c "import os, pathlib; p = pathlib.Path(os.environ['ACT_DIR']) / 'bpy-tbb-malloc-disable.bat'; p.write_text('@echo off\r\nset \"_BPY_PRIOR_TBB_MALLOC_DISABLE_REPLACEMENT=%TBB_MALLOC_DISABLE_REPLACEMENT%\"\r\nset \"TBB_MALLOC_DISABLE_REPLACEMENT=1\"\r\n'); print('wrote', p)"
python -c "import os, pathlib; p = pathlib.Path(os.environ['DEACT_DIR']) / 'bpy-tbb-malloc-disable.bat'; p.write_text('@echo off\r\nif defined _BPY_PRIOR_TBB_MALLOC_DISABLE_REPLACEMENT (set \"TBB_MALLOC_DISABLE_REPLACEMENT=%_BPY_PRIOR_TBB_MALLOC_DISABLE_REPLACEMENT%\") else (set \"TBB_MALLOC_DISABLE_REPLACEMENT=\")\r\nset \"_BPY_PRIOR_TBB_MALLOC_DISABLE_REPLACEMENT=\"\r\n'); print('wrote', p)"

echo ==^> Done.
dir "%SITE_PACKAGES%\bpy"
