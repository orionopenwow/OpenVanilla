@echo off
setlocal
TITLE Open Vanilla - record trailer footage
cd /d "%~dp0"
rem Records trailer footage of every Open Vanilla feature, one video each, without OBS:
rem   Record_Footage.bat                        every scene this PC can run
rem   Record_Footage.bat site-home agents-demo  only those
rem   Record_Footage.bat --list                 what there is and what each needs
rem Videos land in _local\video\raw\<date>\ (one .mp4 per scene, plus each shot on its own).
rem A Chrome window opens and drives itself: hands off the mouse and keyboard while it films.
rem In-game scenes use OWBOT_USER / OWBOT_PASS from .env; Vanilla Agents uses VA_DIR (or your Downloads folder).
where node >nul 2>&1 || (echo Node.js is needed: https://nodejs.org & pause & exit /b 1)
set "PYTHON_EXE="
where py >nul 2>&1 && set "PYTHON_EXE=py -3"
if not defined PYTHON_EXE where python >nul 2>&1 && set "PYTHON_EXE=python"
if not defined PYTHON_EXE (echo Python 3 is needed: https://www.python.org/downloads/ & pause & exit /b 1)
set "CHROMIUM=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROMIUM%" set "CHROMIUM=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROMIUM%" set "CHROMIUM=%LocalAppData%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROMIUM%" set "CHROMIUM=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%CHROMIUM%" (echo Chrome or Edge was not found. & pause & exit /b 1)
if not exist tools\node_modules\playwright (
  echo Installing the browser driver once ^(no browser download^)...
  set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  pushd tools & call npm i --no-save --silent playwright@1.47.2 & popd
)
where ffmpeg >nul 2>&1 || %PYTHON_EXE% -c "import imageio_ffmpeg" >nul 2>&1 || (
  echo Installing ffmpeg for Python once...
  %PYTHON_EXE% -m pip install --user --quiet --disable-pip-version-check imageio-ffmpeg
)
node tools\footage\record.mjs %*
if errorlevel 1 (echo Some scenes did not record - see the lines above. & pause & exit /b 1)
echo.
echo Done. The videos are in _local\video\raw\
pause
