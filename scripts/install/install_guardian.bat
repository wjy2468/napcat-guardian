@echo off
title Install NapCat Guardian
REM === Self-elevate to administrator ===
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================
echo   Installing NapCat Guardian
echo ============================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_guardian.ps1"
echo.
echo Log: %~dp0install_guardian.log
echo ============================================
pause
