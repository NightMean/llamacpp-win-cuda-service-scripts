@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0llama-scripts\start-llamacpp-server.ps1" %*
if %ERRORLEVEL% neq 0 (
    echo.
    echo Server start failed or returned exit code %ERRORLEVEL%.
    pause
)
