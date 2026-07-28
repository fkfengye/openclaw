@echo off
setlocal enabledelayedexpansion

set "WSL_PATH=%~dp0..\.."
set "WSL_PATH=!WSL_PATH:\=/!"

echo [OpenClaw] Starting Gateway...
wsl --cd "!WSL_PATH!" bash -c "export PATH=\"$HOME/.local/node/bin:$HOME/.local/share/pnpm:$PATH\" && nohup pnpm openclaw gateway run --force --allow-unconfigured --bind lan > /tmp/openclaw-gateway.log 2>&1 & disown"

timeout /t 8 /nobreak >nul

wsl fuser 18789/tcp >nul 2>&1
if %ERRORLEVEL% equ 0 (
  echo [OpenClaw] Gateway started successfully.
  echo [OpenClaw] Web UI: http://localhost:18789
) else (
  echo [OpenClaw] Gateway may not have started. Check WSL: cat /tmp/openclaw-gateway.log
)
