@echo off
setlocal
TITLE Open Vanilla - UI Studio
cd /d "%~dp0"
rem UI Studio: tune every Open Vanilla window by hand - drag, resize, recolour, fonts, theme, art.
rem It opens in your browser and writes Data\Interface\AddOns\WenillaCore\Layout.lua as you go.
rem   UI_Studio.bat                                  start it
rem   UI_Studio.bat --game "C:\Games\World of Warcraft"   also point it at your game (for /move positions)
set "PYTHON_EXE="
where py >nul 2>&1 && set "PYTHON_EXE=py -3"
if not defined PYTHON_EXE where python >nul 2>&1 && set "PYTHON_EXE=python"
if not defined PYTHON_EXE (echo Python 3 is needed: https://www.python.org/downloads/ & pause & exit /b 1)
%PYTHON_EXE% -c "import PIL, lupa" >nul 2>&1 || (
  echo Installing Pillow and lupa once...
  %PYTHON_EXE% -m pip install --user --quiet --disable-pip-version-check pillow lupa
)
%PYTHON_EXE% devkit\uistudio\server.py %*
if errorlevel 1 pause
