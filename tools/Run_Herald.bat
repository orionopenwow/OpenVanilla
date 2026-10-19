@echo off
setlocal
TITLE Open Vanilla - Herald test bot
cd /d "%~dp0\.."
rem Runs Herald (tools\owbot.mjs) from this PC against the live realm: signs in, enters the world as
rem Herald the Human Hunter, runs every check and data routine, and writes owbot-summary.txt and
rem owbot-report.json here. Needs Node.js and Chrome or Edge. Credentials come from .env:
rem   REALM_URL=https://play.openvanilla.app   OWBOT_USER=herald   OWBOT_PASS=...
where node >nul 2>&1 || (echo Node.js is needed: https://nodejs.org & pause & exit /b 1)
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
  if /i "%%A"=="REALM_URL" set "REALM_URL=%%B"
  if /i "%%A"=="OWBOT_USER" set "OWBOT_USER=%%B"
  if /i "%%A"=="OWBOT_PASS" set "OWBOT_PASS=%%B"
  if /i "%%A"=="OWBOT_WEBHOOK" set "OWBOT_WEBHOOK=%%B"
)
if not defined REALM_URL set "REALM_URL=https://play.openvanilla.app"
if not defined OWBOT_USER (echo Add OWBOT_USER and OWBOT_PASS to .env first ^(a web login made for the bot in the realm's admin panel^). & pause & exit /b 1)
set "CHROMIUM=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROMIUM%" set "CHROMIUM=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%CHROMIUM%" (echo Chrome or Edge wasn't found. & pause & exit /b 1)
if not exist tools\node_modules\playwright (
  echo Installing the browser driver once ^(no browser download^)...
  set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  pushd tools & call npm i --no-save --silent playwright@1.47.2 & popd
)
node tools\owbot.mjs --full %*
echo.
type owbot-summary.txt
pause
