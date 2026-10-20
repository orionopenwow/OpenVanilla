@echo off
setlocal
TITLE Open Vanilla - Play Solo
cd /d "%~dp0"
REM   "Play Solo.bat"                 Play Solo: your own offline world on this PC (what the launcher's
REM                                  PLAY SOLO button runs). Downloads the solo server once, then starts
REM                                  it in the background, signs you in, and stops it when the game closes.
REM   "Play Solo.bat" solo --mmaps    also build movement maps (optional, an hour or more)
REM   "Play Solo.bat" solo --no-play  start the solo servers only;  "Play Solo.bat" solo-stop  stops them
REM   "Play Solo.bat" status          is the live realm busy right now?
REM
REM   For hosts with SPP Classics (the local test realm):
REM   "Play Solo.bat" host            realm on 127.0.0.1 (this PC)
REM   "Play Solo.bat" lan             realm on this PC's LAN address (friends on your network)
REM   "Play Solo.bat" public HOST     realm on HOST, plus the HTTPS gateway for browser play
REM
REM Solo characters stay on this PC: they can't be moved to the live realm.
set "PYTHON_EXE="
where py >nul 2>&1 && set "PYTHON_EXE=py -3"
if not defined PYTHON_EXE (
    where python >nul 2>&1 && set "PYTHON_EXE=python"
)
if not defined PYTHON_EXE (
    echo Python 3 was not found. Install it from https://www.python.org/downloads/ ^(tick "Add to PATH"^),
    echo or press PLAY SOLO in the Open Vanilla launcher instead: it needs no Python.
    pause
    exit /b 1
)
%PYTHON_EXE% play_local.py %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
