@echo off
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "%~dp0scripts\Ensure-HomelabJobEngine.ps1"
if errorlevel 1 (
  echo Homelab Job Engine konnte nicht gestartet werden.
  pause
  exit /b 1
)
start "" "http://127.0.0.1:8770/"
