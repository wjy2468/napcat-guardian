@echo off
title QQ Bot One-Click Launcher
REM ============================================================
REM  One-click start: AstrBot + NapCat.
REM  EDIT the paths below to match your installation.
REM ============================================================

REM --- EDIT THESE ---
set "PYTHON=C:\Users\YOUR_NAME\AppData\Local\Programs\Python\Python314\python.exe"
set "ASTRBOT=C:\Users\YOUR_NAME\qq-deepseek-bot\astrbot"
set "NAPCAT=D:\napcat\NapCat.Shell"
set "QQ_UIN=YOUR_BOT_QQ"
REM Optional: add ffmpeg to PATH (leave empty if not needed).
set "FFMPEG=D:\tools\ffmpeg\bin"

echo ========================================
echo   QQ Bot One-Click Launcher
echo ========================================
if not exist "%PYTHON%" ( echo [ERROR] Python not found: %PYTHON% & pause & exit /b 1 )
if not exist "%ASTRBOT%\main.py" ( echo [ERROR] AstrBot main.py not found & pause & exit /b 1 )
if not exist "%NAPCAT%\launcher.bat" ( echo [ERROR] NapCat launcher.bat not found & pause & exit /b 1 )

echo [1/3] Starting AstrBot (minimized) ...
start "AstrBot" /min cmd /k "cd /d "%ASTRBOT%" && set PATH=%PATH%;%FFMPEG% && "%PYTHON%" main.py"

echo Waiting 8 seconds for AstrBot to load plugins ...
timeout /t 8 /nobreak >nul

echo [2/3] Starting NapCat with quick login ...
start "NapCat" cmd /k "cd /d "%NAPCAT%" && launcher.bat %QQ_UIN%"

echo [3/3] Done. A UAC prompt may appear; click Yes.
echo ========================================
pause
