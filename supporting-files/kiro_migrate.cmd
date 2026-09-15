@echo off
rem Windows launcher for kiro_migrate.ps1 (same arguments as kiro_migrate.sh). Usage: kiro_migrate.cmd [source\usp_X.sql ...]
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0kiro_migrate.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kiro_migrate.ps1" %*
)
exit /b %ERRORLEVEL%
