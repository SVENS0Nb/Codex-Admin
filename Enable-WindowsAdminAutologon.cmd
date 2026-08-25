@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-WindowsAdminAutologonElevation.ps1"
if errorlevel 1 (
  echo.
  echo Windows-Autologon konnte nicht eingerichtet werden.
  pause
  exit /b 1
)
