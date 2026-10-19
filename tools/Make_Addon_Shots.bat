@echo off
setlocal
TITLE Open Vanilla - website addon pictures
cd /d "%~dp0.."
set "PY="
where py >nul 2>&1 && set "PY=py -3"
if not defined PY (where python >nul 2>&1 && set "PY=python")
if not defined PY (echo Python 3 is needed: https://www.python.org/downloads/ & pause & exit /b 1)
%PY% tools\addon_shots.py
echo.
echo Pictures are in www\assets\addons. Tell Claude when all 10 are there.
pause
