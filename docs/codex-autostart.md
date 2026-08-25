# Codex desktop autostart

The optional scheduled task `CodexAdmin - Codex Desktop Autostart` starts the
installed Codex desktop package at interactive logon for the current Windows
user. It first ensures the loopback Job Engine is healthy and never runs Codex
as SYSTEM.

Install or repair it only after review:

```powershell
Set-Location C:\Codex-Admin
.\scripts\Install-CodexDesktopAutostart.ps1
```

Verify the task and launcher:

```powershell
Get-ScheduledTask -TaskName 'CodexAdmin - Codex Desktop Autostart'
.\scripts\Start-CodexDesktop.ps1
```

An interactive session must exist. Automatic Windows logon is a separate,
optional security decision described in `docs/windows-autologon.md`.
