@echo off
rem Windows launcher for run_tests.ps1 (same arguments as run_tests.sh). Usage: run_tests.cmd [--project|--skill]
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_tests.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_tests.ps1" %*
)
exit /b %ERRORLEVEL%
