@echo off
setlocal EnableExtensions
cd /d "%~dp0"

if /i "%~1"=="help" goto :help
if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help

set "LAUNCH_MODE=console"
if /i "%~1"=="gui" set "LAUNCH_MODE=gui"
set "VENV_RECREATE_DONE=0"
set "IMPORT_REPAIR_DONE=0"

rem UTF-8 in console and Python to avoid path/log encoding issues
chcp 65001 >nul 2>&1
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"

rem Local ffmpeg (essentials) beside the project — no system installation required
if exist "%~dp0ffmpeg-runtime\bin\ffmpeg.exe" (
    set "PATH=%~dp0ffmpeg-runtime\bin;%PATH%"
)

title Photo AI Sorter

echo.
echo  ========================================
echo   Photo AI Sorter — launch
echo  ========================================
echo.

if not exist "requirements.txt" (
    echo [ERROR] requirements.txt was not found in the project folder.
    echo Expected: "%~dp0requirements.txt"
    goto :fail
)

set "HAVE_PY=0"
where python >nul 2>&1 && set "HAVE_PY=1"
if "%HAVE_PY%"=="0" (
    where py >nul 2>&1 && set "HAVE_PY=2"
)
if "%HAVE_PY%"=="0" (
    echo [ERROR] Python not found. Python 3.10+ must be in PATH or available through the `py` launcher.
    echo Download: https://www.python.org/downloads/ ^(check “Add python.exe to PATH”^).
    goto :fail
)

:create_venv
if not exist ".venv\Scripts\python.exe" (
    echo [1/3] Creating virtual environment .venv ...
    if "%HAVE_PY%"=="1" (
        python -m venv .venv
    ) else (
        py -3 -m venv .venv
    )
    if errorlevel 1 (
        echo [ERROR] Failed to create venv.
        goto :fail
    )
    echo       Done.
) else (
    echo [1/3] Virtual environment .venv already exists.
)

set "PY=%CD%\.venv\Scripts\python.exe"
set "PYW=%CD%\.venv\Scripts\pythonw.exe"
set "DEPS_MARKER=%CD%\.venv\.photo_ai_sorter_deps_ok"

"%PY%" -c "import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)" >nul 2>&1
if errorlevel 1 (
    if "%VENV_RECREATE_DONE%"=="1" (
        echo [ERROR] Python 3.10+ is required. Check your system Python and rerun the launcher.
        goto :fail
    )
    echo [1/3] .venv is damaged or was created with an older Python version — recreating ...
    call :remove_venv
    if errorlevel 1 (
        echo [ERROR] Could not remove old .venv. Close Python processes and try again.
        goto :fail
    )
    set "VENV_RECREATE_DONE=1"
    goto :create_venv
)

echo [2/3] Checking dependencies ...
set "NEED_INSTALL=0"
if not exist "%DEPS_MARKER%" set "NEED_INSTALL=1"
if "%NEED_INSTALL%"=="0" (
    "%PY%" -c "from pathlib import Path; import sys; req=Path('requirements.txt'); marker=Path(r'.venv/.photo_ai_sorter_deps_ok'); sys.exit(0 if marker.exists() and marker.stat().st_mtime >= req.stat().st_mtime else 1)" >nul 2>&1
    if errorlevel 1 set "NEED_INSTALL=1"
)

if "%NEED_INSTALL%"=="1" (
    echo       Installing/updating pip and packages ...
    "%PY%" -m pip install --upgrade pip setuptools wheel -q --disable-pip-version-check
    if errorlevel 1 goto :pip_fail
    "%PY%" -m pip install -r requirements.txt --upgrade -q --disable-pip-version-check
    if errorlevel 1 goto :pip_fail
    "%PY%" -c "from pathlib import Path; Path(r'.venv/.photo_ai_sorter_deps_ok').write_text('ok', encoding='utf-8')"
    if errorlevel 1 goto :pip_fail
    echo       Done.
) else (
    echo       Dependencies are already up to date.
)

where nvidia-smi >nul 2>&1
if not errorlevel 1 (
    "%PY%" -c "import torch; import sys; sys.exit(0 if torch.cuda.is_available() else 1)" >nul 2>&1
    if errorlevel 1 (
        echo [2/3] NVIDIA GPU detected — installing PyTorch with CUDA ^(cu126^) ...
        rem --force-reinstall --no-deps: a CPU torch of the same version already
        rem satisfies torch>=..., so --upgrade is a no-op; force the CUDA wheel,
        rem --no-deps keeps numpy/pillow (absent from the pytorch index) intact.
        "%PY%" -m pip install -r requirements-gpu.txt --force-reinstall --no-deps -q --disable-pip-version-check
        if errorlevel 1 (
            echo [WARNING] Could not install torch+cuda. CLIP will use CPU.
        ) else (
            echo       PyTorch CUDA installed.
        )
    )
)

if /i "%~1"=="test" (
    "%PY%" -m pip install -r requirements-dev.txt --upgrade -q --disable-pip-version-check
    if errorlevel 1 goto :pip_fail_dev
)

echo [3/3] Checking environment ...
"%PY%" -c "import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)"
if errorlevel 1 (
    echo [ERROR] Python 3.10+ is required. The current .venv uses another version — delete the .venv folder and rerun the script.
    goto :fail
)

"%PY%" -m compileall -q app main.py
if errorlevel 1 (
    echo [ERROR] Python compilation error ^(syntax^).
    goto :fail
)
"%PY%" -c "import app.gui; import app.gui_duplicates; import app.duplicate_finder; import app.duplicate_worker; import app.signature_db; import app.worker; import app.lm_studio; import app.settings_store; import app.video_frames; print('Import check: OK')"
if errorlevel 1 (
    if "%IMPORT_REPAIR_DONE%"=="0" (
        echo [3/3] Imports failed — recreating .venv from scratch and retrying installation ...
        call :remove_venv
        if errorlevel 1 (
            echo [ERROR] Could not remove old .venv. Close Python processes and try again.
            goto :fail
        )
        set "IMPORT_REPAIR_DONE=1"
        set "VENV_RECREATE_DONE=1"
        goto :create_venv
    )
    echo [ERROR] Failed to import application ^(see message above^).
    echo Try manually: "%PY%" -m pip install -r requirements.txt -v
    goto :fail
)

if /i "%~1"=="test" goto :run_tests

echo.
echo       Launching GUI ...
echo.
if /i "%LAUNCH_MODE%"=="gui" if exist "%PYW%" (
    start "Photo AI Sorter" "%PYW%" "%CD%\main.py"
    exit /b 0
)

"%PY%" main.py
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
    echo.
    echo [EXIT] Error code: %EXITCODE%
    goto :fail
)
echo.
echo Application closed normally.
exit /b 0

:run_tests
echo.
echo       Running tests ^(pytest^) ...
echo.
"%PY%" -m pytest -q
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
    echo.
    echo [TESTS] Exit code: %EXITCODE%
    goto :fail
)
echo.
echo Tests passed.
exit /b 0

:pip_fail
echo.
echo [ERROR] pip install failed.
echo Diagnostics: retry without -q; output follows.
echo.
"%PY%" -m pip install -r requirements.txt --upgrade --disable-pip-version-check
goto :fail

:pip_fail_dev
echo.
echo [ERROR] pip install of development dependencies failed.
echo Diagnostics: retry without -q; output follows.
echo.
"%PY%" -m pip install -r requirements-dev.txt --upgrade --disable-pip-version-check
goto :fail

:help
echo Usage:
echo   run.bat           — create/update .venv, install dependencies, checks, launch GUI
echo   run.bat gui       — same, but GUI launches via pythonw.exe for double-click
echo   run.bat test      — same, then pytest -q
echo   run.bat help      — this help
echo.
exit /b 0

:remove_venv
set "REMOVE_TRIES=0"
:remove_venv_retry
if not exist ".venv" exit /b 0
rmdir /s /q ".venv" >nul 2>&1
if not exist ".venv" exit /b 0
set /a REMOVE_TRIES+=1 >nul
if %REMOVE_TRIES% LSS 5 (
    timeout /t 2 /nobreak >nul
    goto :remove_venv_retry
)
exit /b 1

:fail
echo.
pause
exit /b 1
