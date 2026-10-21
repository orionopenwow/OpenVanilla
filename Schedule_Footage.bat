@echo off
setlocal
TITLE Open Vanilla - nightly trailer footage
cd /d "%~dp0"
rem Schedule_Footage.bat           record every scene by itself every night at 3:30 (or: Schedule_Footage.bat 04:15)
rem Schedule_Footage.bat off       stop the nightly recording
rem Schedule_Footage.bat now       run tonight's recording right away (to try it)
rem It runs only while you are signed in to Windows (the game needs your graphics card and a desktop),
rem and it waits until the PC has been idle for 10 minutes, so it never films over you. Leave the PC
rem on and signed in (locking the screen is fine). Results: _local\video\raw\<date>\ and reel.mp4,
rem the newest 7 nights kept; _local\video\raw\LATEST.txt says what the last run made; record.log has the details.
set "TASK=Open Vanilla footage"
if /i "%~1"=="off" (
  schtasks /Delete /TN "%TASK%" /F && echo Nightly recording is off.
  pause & exit /b 0
)
if /i "%~1"=="now" (
  schtasks /Run /TN "%TASK%" && echo Recording started in the background. Hands off the mouse and keyboard for a while.
  pause & exit /b 0
)
set "AT=%~1"
if "%AT%"=="" set "AT=03:30"
schtasks /Create /TN "%TASK%" /TR "\"%~dp0Record_Footage.bat\" --auto" /SC DAILY /ST %AT% /IT /F >nul
if errorlevel 1 (echo Could not create the scheduled task. & pause & exit /b 1)
rem only when the PC has been idle 10 minutes; keep going if you come back; at most 2 hours
powershell -NoProfile -Command "$t = Get-ScheduledTask -TaskName '%TASK%'; $s = $t.Settings; $s.RunOnlyIfIdle = $true; $s.IdleSettings.IdleDuration = 'PT10M'; $s.IdleSettings.WaitTimeout = 'PT2H'; $s.IdleSettings.StopOnIdleEnd = $false; $s.ExecutionTimeLimit = 'PT2H'; $s.StartWhenAvailable = $true; $s.DisallowStartIfOnBatteries = $false; Set-ScheduledTask -TaskName '%TASK%' -Settings $s | Out-Null" 2>nul
echo Nightly recording is on: every day at %AT% (when the PC is idle and you are signed in).
echo   Try it now:  Schedule_Footage.bat now
echo   Turn it off: Schedule_Footage.bat off
pause
