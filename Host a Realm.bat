@echo off
TITLE Open Vanilla Server
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

REM What the server panel and the realm website need, installed once.
%PY% -c "import aiohttp, PIL, psutil, pymysql" >nul 2>&1 || (
    echo Installing what Open Vanilla Server needs ^(one time^)...
    %PY% -m pip install --user --quiet "aiohttp>=3.8" "pillow>=9" "psutil>=5.9" "pymysql>=1.0"
)

%PY% openvanilla_server.py %*
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Open Vanilla Server stopped with an error. Press any key to close.
    pause
)
