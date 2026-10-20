@echo off
TITLE Open Vanilla Model Porter
cd /d "%~dp0"

REM Drop .glb / .gltf files on this file, or double-click it: the porter opens in your browser.
REM Find Python 3: the py launcher first, then python on PATH.
set "PYTHON_EXE="
where py >nul 2>&1 && set "PYTHON_EXE=py -3"
if not defined PYTHON_EXE (
    where python >nul 2>&1 && set "PYTHON_EXE=python"
)
if not defined PYTHON_EXE (
    echo Python 3 was not found. Install it from https://www.python.org/downloads/ ^(tick "Add to PATH"^).
    pause
    exit /b 1
)

REM First run: the three packages the porter needs (numpy, Pillow, fast-simplification).
%PYTHON_EXE% -c "import numpy, PIL" >nul 2>&1
if errorlevel 1 (
    echo Installing numpy and Pillow ^(first run only^)...
    %PYTHON_EXE% -m pip install --user --quiet numpy pillow
)
%PYTHON_EXE% -c "import fast_simplification" >nul 2>&1
if errorlevel 1 (
    %PYTHON_EXE% -m pip install --user --quiet fast-simplification >nul 2>&1
)

%PYTHON_EXE% tools\modelport --app %*
if errorlevel 1 (
    echo.
    echo The Model Porter stopped with an error. Press any key to close.
    pause >nul
)
