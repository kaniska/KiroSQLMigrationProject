@echo off
rem Windows launcher for pgtest.ps1 (same arguments as pgtest.sh). Usage: pgtest.cmd <manifest.sql> [-Results FILE]
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0pgtest.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pgtest.ps1" %*
)
exit /b %ERRORLEVEL%
