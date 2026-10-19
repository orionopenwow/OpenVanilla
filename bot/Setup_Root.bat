@echo off
setlocal
TITLE Open Vanilla - build the Root community layout
cd /d "%~dp0root"
chcp 65001 >nul
where node >nul 2>&1 || (echo Node.js 22 or newer is needed: https://nodejs.org/ & pause & exit /b 1)
for /f "tokens=1 delims=v." %%v in ('node -v') do set NODEMAJOR=%%v
if %NODEMAJOR% LSS 22 (echo Node.js 22 or newer is needed, please update: https://nodejs.org/ & pause & exit /b 1)

rem The bot's ID (Root Developer Portal -> My bots -> your bot) goes in root-manifest.json, once.
findstr /c:"your-bot-id" root-manifest.json >nul && (
  echo.
  echo  First time: open https://dev.rootapp.com, sign in, My bots, New bot, name it "Open Vanilla Herald".
  echo  Copy the bot's ID from its page.
  echo.
  set /p BOTID=  Paste the bot ID and press Enter: 
)
if defined BOTID powershell -NoProfile -Command "(Get-Content root-manifest.json -Raw) -replace 'your-bot-id', '%BOTID%' | Set-Content root-manifest.json -NoNewline -Encoding utf8"

rem The DEV_TOKEN picks the community the setup builds in. Keep it secret, like a password.
if not exist .env copy .env.example .env >nul
findstr /c:"paste-your-dev-token-here" .env >nul && (
  echo.
  echo  Developer Portal -^> My bots -^> your bot -^> Settings -^> Generate new dev token -^> Generate. Copy it.
  echo.
  set /p DEVTOKEN=  Paste the DEV_TOKEN and press Enter: 
)
if defined DEVTOKEN (> .env echo DEV_TOKEN=%DEVTOKEN%)

if not exist node_modules (echo Installing the Root SDK, one time... & call npm install --no-fund --no-audit || (pause & exit /b 1))
call npm run build || (echo The build failed: see the errors above. & pause & exit /b 1)
echo.
echo  Building the Open Vanilla layout. Watch for "DONE", then close this window.
echo.
call npm run bot
pause
