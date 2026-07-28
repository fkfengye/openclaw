@echo off
echo Stopping OpenClaw Gateway...
wsl pkill -f "openclaw-gatewa" >nul 2>&1
if %ERRORLEVEL% equ 0 (
  echo Gateway stopped.
) else (
  echo Gateway is not running.
)
