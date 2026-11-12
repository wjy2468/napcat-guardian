@echo off
title QQ Bot One-Click Launcher
REM ============================================================
REM  One-click start: AstrBot + NapCat, both WITHOUT console windows.
REM
REM   [1] AstrBot  : started by your user-level watchdog script
REM                  (astrbot_watchdog.ps1, kept alive by itself).
REM   [2] NapCat   : triggered through the NapCatGuardian scheduled
REM                  task, which launches it hidden (CreateNoWindow).
REM
REM  For unattended use install the scheduled task once
REM  (install_guardian.bat, as administrator).
REM ============================================================
setlocal
set "HERE=%~dp0"

echo ========================================
echo   QQ Bot One-Click Launcher
echo ========================================

if not exist "%HERE%astrbot_watchdog.ps1" (
    echo [ERROR] astrbot_watchdog.ps1 not found next to this file.
    pause & exit /b 1
)

echo [1/2] Starting AstrBot watchdog (hidden) ...
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HERE%astrbot_watchdog.ps1"

echo [2/2] Triggering NapCat via scheduled task ...
schtasks /run /tn "NapCatGuardian" >nul 2>&1
if errorlevel 1 (
    echo [WARN] Scheduled task NapCatGuardian not found.
    echo        Run install_guardian.bat as administrator once.
)

echo.
echo Done. Give it ~2 minutes, then check:
echo   NapCat WebUI : http://127.0.0.1:6099
echo   AstrBot WebUI: http://127.0.0.1:6185
echo.
pause