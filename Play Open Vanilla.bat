@echo off
setlocal EnableDelayedExpansion
title Open Vanilla
cd /d "%~dp0"
rem Play Open Vanilla.bat - opens the Open Vanilla launcher from this folder.
rem   It is the same launcher as OpenVanilla.exe in the download, run from the source code.
rem   First run: finds Python 3.10 or newer and installs Pillow (the launcher's image library) for you.
rem   "Play Open Vanilla.bat" debug    keeps this window open and shows any error messages.

set "PY="
where py >nul 2>&1 && py -3 -c "import sys; sys.exit(sys.version_info < (3, 10))" >nul 2>&1 && set "PY=py -3"
if not defined PY where python >nul 2>&1 && python -c "import sys; sys.exit(sys.version_info < (3, 10))" >nul 2>&1 && set "PY=python"
if not defined PY goto :nopython

%PY% -c "import tkinter, PIL" >nul 2>&1
if errorlevel 1 (
  echo First run: installing Pillow, the launcher's image library. This takes a few seconds...
  %PY% -m pip install --user --quiet --disable-pip-version-check pillow
  %PY% -c "import tkinter, PIL" >nul 2>&1 || goto :nodeps
)

if /i "%~1"=="debug" (
  %PY% "launcher\openvanilla_launcher.py"
  echo.
  echo The launcher closed ^(exit code !ERRORLEVEL!^).
  pause
  exit /b 0
)

rem Start without a console window behind the launcher.
set "PYW=%PY%"
if "%PY%"=="py -3" (where pyw >nul 2>&1 && set "PYW=pyw -3")
if "%PY%"=="python" (where pythonw >nul 2>&1 && set "PYW=pythonw")
start "" %PYW% "launcher\openvanilla_launcher.py" %*
exit /b 0

:nopython
echo.
echo   Open Vanilla runs from this folder with Python 3.10 or newer, which wasn't found.
echo.
echo   Easiest: install Open Vanilla instead. One download, no Python needed.
echo   Opening the download page...
start "" "https://github.com/orionopenwow/OpenVanilla/releases/latest"
echo.
echo   Or install Python from https://www.python.org/downloads/
echo   ^(tick "Add python.exe to PATH"^), then double-click "Play Open Vanilla.bat" again.
echo.
pause
exit /b 1

:nodeps
echo.
echo   Pillow could not be installed. In this window, run:
echo     %PY% -m pip install --user pillow
echo   then double-click "Play Open Vanilla.bat" again.
echo.
pause
exit /b 1
