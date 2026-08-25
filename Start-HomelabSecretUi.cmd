@echo off
setlocal
title Homelab Secret UI
cd /d "%~dp0apps\secret-ui"

pwsh.exe -NoLogo -NoProfile -NonInteractive -Command "try { $response = Invoke-WebRequest -Uri 'http://127.0.0.1:8765/healthz' -TimeoutSec 2; if ($response.StatusCode -eq 200) { Start-Process 'http://127.0.0.1:8765'; exit 0 } } catch {}; exit 1"
if not errorlevel 1 exit /b 0

where node.exe >nul 2>nul
if errorlevel 1 (
  echo Node.js wurde nicht gefunden.
  echo Installiere Node.js oder pruefe den PATH.
  pause
  exit /b 1
)

node.exe server.mjs
if errorlevel 1 pause
