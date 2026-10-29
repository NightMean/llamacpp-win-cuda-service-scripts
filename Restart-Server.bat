@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0llama-scripts\restart-llamacpp-server.ps1" %*
if %ERRORLEVEL% neq 0 (
    echo.
    echo Server restart returned exit code %ERRORLEVEL%.
    pause
)
