@echo off
TITLE Herald Autopilot
cd /d "%~dp0"

REM Find Python 3: the py launcher first, then python on PATH.
set "PY="
where py >nul 2>&1 && set "PY=py -3"
if not defined PY (
    where python >nul 2>&1 && set "PY=python"
)
if not defined PY (
    echo Python 3 was not found. Install it from https://www.python.org/downloads/ ^(tick "Add to PATH"^), then run this again.
    pause
    exit /b 1
)

REM Pillow draws the window's art; installed once.
%PY% -c "import PIL" >nul 2>&1 || (
    echo Installing what Herald Autopilot needs ^(one time^)...
    %PY% -m pip install --user --quiet "pillow>=9"
)

%PY% autopilot\herald_autopilot.py %*
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Herald Autopilot stopped with an error. Press any key to close.
    pause
)
