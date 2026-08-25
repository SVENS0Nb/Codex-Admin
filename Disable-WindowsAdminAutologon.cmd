@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-WindowsAdminAutologonElevation.ps1" -Mode Disable
if errorlevel 1 (
  echo.
  echo Windows-Autologon konnte nicht deaktiviert werden.
  pause
  exit /b 1
)
