@echo off
setlocal
TITLE Vanilla Forge
cd /d "%~dp0"
rem Vanilla Forge, the creator app, in one double-click.
rem   1. the portable Forge in forge\bin\Vanilla Forge (fetched here the first time), or
rem   2. Forge from its installer, or
rem   3. the newest portable zip from the Forge release (openvanilla.app/downloads/forge.json, checked by
rem      its SHA-256), unzipped into forge\bin, or
rem   4. built from the forge folder with Rust, if you have it.
rem   "Vanilla Forge.bat" --update     fetch the newest portable Forge again
set "APP=%~dp0forge\bin\Vanilla Forge\Vanilla Forge.exe"
if /i "%~1"=="--update" (
  if exist "%~dp0forge\bin\Vanilla Forge" rmdir /s /q "%~dp0forge\bin\Vanilla Forge"
  shift
)
if exist "%APP%" goto run
for %%E in ("%LOCALAPPDATA%\Vanilla Forge\Vanilla Forge.exe" "%LOCALAPPDATA%\Vanilla Forge\openvanilla-forge.exe" "%ProgramFiles%\Vanilla Forge\Vanilla Forge.exe" "%ProgramFiles%\Vanilla Forge\openvanilla-forge.exe") do (
  if exist %%E ( start "" %%E & exit /b 0 )
)

echo Getting Vanilla Forge (once; it goes in forge\bin, nothing is installed)...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $ProgressPreference='SilentlyContinue';" ^
  "$f = Invoke-RestMethod 'https://openvanilla.app/downloads/forge.json';" ^
  "if (-not $f.zip_url) { throw 'The Forge release has no portable zip yet.' }" ^
  "if ($f.zip_url -notmatch '^https://github\.com/orionopenwow/') { throw 'Unexpected download address.' }" ^
  "Write-Host ('  Vanilla Forge ' + $f.version + ', ' + [math]::Round($f.zip_size / 1MB) + ' MB');" ^
  "$z = Join-Path $env:TEMP $f.zip; Invoke-WebRequest $f.zip_url -OutFile $z;" ^
  "if ((Get-FileHash $z -Algorithm SHA256).Hash.ToLower() -ne $f.zip_sha256) { Remove-Item $z; throw 'The download did not match its SHA-256: not used.' }" ^
  "New-Item -ItemType Directory 'forge\bin' -Force | Out-Null; Expand-Archive $z -DestinationPath 'forge\bin' -Force; Remove-Item $z"
if not errorlevel 1 if exist "%APP%" goto run

where cargo >nul 2>&1 || goto nohelp
echo No portable Forge to fetch: building it from the forge folder with Rust (the first time takes a while)...
pushd forge
cargo run --release -p openvanilla-forge
popd
exit /b 0

:run
start "" "%APP%"
exit /b 0

:nohelp
echo.
echo Vanilla Forge couldn't be fetched just now. Download it from https://openvanilla.app/forge.html
echo (the installer, or the portable zip: unzip it anywhere and run Vanilla Forge.exe).
pause
exit /b 1
