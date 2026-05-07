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

REM NOTE: an earlier attempt renamed lib\windows_x64\python\ when
REM PY_VER didn't match the bundle's python — but Blender 3.6's
REM platform_win32.cmake hardcodes the lookup at
REM `${LIBDIR}/python/310` (no dot), and the rename also broke the
REM official combo. The off-spec combos (3.6+py3.11+, 4.2+py3.12+,
REM 5.1+py3.14) require source-level Blender patches; we accept
REM PyPI's per-Blender-Python pinning instead. Cells dropped from
REM packages/*.yml.
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
REM   tbbmalloc_proxy*               — already stripped below.
REM
REM Without this skip-list, official combos pass (bundle's python ==
REM env's python, no conflict) but off-spec combos crash deterministically.
echo ==^> DLL backstop: copying missing bundled DLLs into bpy\ (skip-list applied)
for /R "%SRC_DIR%\lib\windows_x64" %%F in (*.dll) do (
    if not exist "%SITE_PACKAGES%\bpy\%%~nxF" (
        echo %%~nxF | findstr /B /I /R "^python[0-9] ^vcruntime ^msvcp ^ucrtbase ^vcomp ^libomp ^libiomp5 ^tbbmalloc_proxy" >nul && (
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
