@echo off
setlocal EnableDelayedExpansion
TITLE Open Vanilla devkit
cd /d "%~dp0\.."
rem The devkit menu. Everything here runs on this PC; nothing is pushed. See devkit\README.md.
set "PY="
where py >nul 2>&1 && set "PY=py -3"
if not defined PY (where python >nul 2>&1 && set "PY=python")
if not defined PY (echo Python 3 is needed: https://www.python.org/downloads/ & pause & exit /b 1)
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
  if /i "%%A"=="REALM_URL" set "REALM_URL=%%B"
  if /i "%%A"=="OWBOT_USER" set "OWBOT_USER=%%B"
  if /i "%%A"=="OWBOT_PASS" set "OWBOT_PASS=%%B"
  if /i "%%A"=="HL_WEB" set "HL_WEB=%%B"
  if /i "%%A"=="HL_USER" set "HL_USER=%%B"
  if /i "%%A"=="HL_PASS" set "HL_PASS=%%B"
)
if not defined REALM_URL set "REALM_URL=https://play.openvanilla.app"
if not defined HL_WEB set "HL_WEB=https://staging.openvanilla.app"

:menu
echo.
echo  Open Vanilla devkit
echo  ----------------------------------------------------------------
echo   1  Quick checks         addons, patch-Z, scripts, versions (seconds)
echo   2  Addon tests          every Classic+ addon in a fake game (needs Lua 5.1)
echo   3  SQL tests            our SQL on a throwaway database (needs Docker)
echo   4  Dev proxy            play the live realm with YOUR local files, no push
echo   5  Herald Lite          headless test bot against staging (needs Rust)
echo   6  Full Herald          browser test bot against live (needs Node + Chrome)
echo   7  Measure loading      load times and bytes, cold and warm (needs Node + Chrome)
echo   8  Rebuild patch-Z      make patch-Z.MPQ match Data\Interface (needs Docker)
echo   9  All local tests      1, 2 and 3
echo   0  Quit
echo.
set "C="
set /p C=Choose: 
if "%C%"=="1" goto :check
if "%C%"=="2" goto :sim
if "%C%"=="3" goto :sql
if "%C%"=="4" goto :proxy
if "%C%"=="5" goto :hl
if "%C%"=="6" goto :herald
if "%C%"=="7" goto :measure
if "%C%"=="8" goto :patchz
if "%C%"=="9" goto :all
if "%C%"=="0" exit /b 0
goto :menu

:check
%PY% devkit\check.py
goto :done

:sim
set "LUA="
for %%L in (lua5.1 lua51 lua) do if not defined LUA (where %%L >nul 2>&1 && set "LUA=%%L")
if not defined LUA (
  where wsl >nul 2>&1 && (wsl lua5.1 devkit/sim/run_tests.lua & goto :done)
  echo Lua 5.1 isn't installed. GitHub runs these tests on every push anyway.
  echo To run them here: install Lua 5.1 ^(luabinaries.sourceforge.net, lua5_1_4_Win64_bin^) and put lua5.1.exe on PATH.
  goto :done
)
%LUA% devkit\sim\run_tests.lua
goto :done

:sql
where docker >nul 2>&1 || (echo Docker Desktop is needed: https://www.docker.com/products/docker-desktop & goto :done)
%PY% devkit\db\test_sql.py
goto :done

:proxy
%PY% -c "import aiohttp" >nul 2>&1 || %PY% -m pip install -q aiohttp
start "" http://localhost:8080/
%PY% devkit\proxy\devproxy.py --upstream %REALM_URL% --port 8080 --repo .
goto :done

:hl
where cargo >nul 2>&1 || (echo Rust is needed: https://rustup.rs & goto :done)
if not defined HL_USER (echo Add HL_USER and HL_PASS ^(Herald's staging login^) to .env first. & goto :done)
pushd devkit\heraldlite
if not exist target\release\heraldlite.exe cargo build --release || (popd & goto :done)
target\release\heraldlite.exe --web %HL_WEB% -s scenarios\smoke.txt -s scenarios\wallet.txt -s scenarios\skills.txt --pretty
popd
goto :done

:herald
call tools\Run_Herald.bat
goto :menu

:measure
where node >nul 2>&1 || (echo Node.js is needed: https://nodejs.org & goto :done)
set "CHROMIUM=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROMIUM%" set "CHROMIUM=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist tools\node_modules\playwright (pushd tools & set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1& call npm i --no-save --silent playwright@1.47.2 & popd)
set "PLAYWRIGHT_MODULE=%cd%\tools\node_modules\playwright\index.mjs"
node devkit\loadlab\measure.mjs --url %REALM_URL% --out devkit\loadlab\last.json
goto :done

:patchz
where docker >nul 2>&1 || (echo Docker Desktop is needed: https://www.docker.com/products/docker-desktop & goto :done)
docker build -q -t openvanilla-patchz devkit\patchz >nul || goto :done
docker run --rm -v "%cd%":/repo openvanilla-patchz
goto :done

:all
%PY% devkit\check.py
call :simq
where docker >nul 2>&1 && %PY% devkit\db\test_sql.py
goto :done

:simq
for %%L in (lua5.1 lua51) do (where %%L >nul 2>&1 && (%%L devkit\sim\run_tests.lua & exit /b 0))
echo (addon tests skipped: no Lua 5.1 here; GitHub runs them)
exit /b 0

:done
echo.
pause
goto :menu
