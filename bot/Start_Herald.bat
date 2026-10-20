@echo off
setlocal
TITLE Open Vanilla Herald (Discord bot) - keep this window open
cd /d "%~dp0"
chcp 65001 >nul
set "PYTHONUTF8=1"
set "PY="
where py >nul 2>&1 && set "PY=py -3"
if not defined PY (where python >nul 2>&1 && set "PY=python")
if not defined PY (echo Python 3 is needed: https://www.python.org/downloads/ & pause & exit /b 1)
echo The Herald runs the gate (Outsider - Recruit - Adventurer), the raid shield, #arrivals and #server-status while this window is open.
echo For 24/7 run it on the server instead: hetzner\herald_up.sh
%PY% -c "import discord, pymysql" >nul 2>&1 || (echo Installing what Herald needs ^(one time^)... & %PY% -m pip install --user --quiet "discord.py>=2.3" "pymysql>=1.0")
%PY% herald.py
pause
