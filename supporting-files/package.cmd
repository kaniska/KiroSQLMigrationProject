@echo off
rem Windows launcher for package.ps1 (same arguments as package.sh). Usage: package.cmd [--out FILE] [--include-logs]
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0package.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package.ps1" %*
)
exit /b %ERRORLEVEL%
