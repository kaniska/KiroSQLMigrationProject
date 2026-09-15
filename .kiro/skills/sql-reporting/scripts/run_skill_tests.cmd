@echo off
rem Windows launcher for run_skill_tests.ps1 (same arguments as run_skill_tests.sh). Usage: run_skill_tests.cmd
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_skill_tests.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_skill_tests.ps1" %*
)
exit /b %ERRORLEVEL%
