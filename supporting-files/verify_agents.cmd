@echo off
rem Windows launcher for verify_agents.ps1 (same arguments as verify_agents.sh: --smoke -> -Smoke). Usage: verify_agents.cmd [--smoke]
setlocal
set ARGS=%*
set ARGS=%ARGS:--smoke=-Smoke%
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_agents.ps1" %ARGS%
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_agents.ps1" %ARGS%
)
exit /b %ERRORLEVEL%
