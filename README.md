# Codex-Admin

Codex-Admin is a reproducible, Windows-hosted control plane for administering an
authorized homelab with Codex. It combines a structured operational knowledge
base, an MCP server, a loopback-only job engine, a Windows DPAPI-backed secret
UI, read-only diagnostics, recurring log review, and recovery tests.

The repository is deliberately site-neutral. Every tracked address, host name,
identifier, and credential reference is synthetic. A real deployment stores its
site overlay under `%LOCALAPPDATA%\CodexAdmin\site`; plaintext credentials never
belong in Git or in the knowledge database.

## Components

- `mcp/homelab-admin`: structured systems, facts, observations, incidents,
  decisions, maintenance, capabilities, access references, and task contracts.
- `apps/job-engine`: loopback scheduler for recurring, one-time, and bounded
  active-test jobs with Codex task reactivation and sanitized audit history.
- `apps/secret-ui`: local DPAPI-backed storage for passwords, API keys, SSH keys,
  and TOTP seeds.
- `apps/unifi-security-log`: optional read-only UniFi security-event archive.
- `scripts`: installation, diagnostics, safety checks, backup, restore, and
  control-plane maintenance.

## Quick start

Requirements are Windows 11 or Windows Server, PowerShell 7, Git, Node.js 24,
Python 3.11 or newer, and the Codex desktop application or CLI.

```powershell
git clone https://github.com/SVENS0Nb/Codex-Admin.git C:\Codex-Admin
Set-Location C:\Codex-Admin
pwsh -NoProfile -File .\scripts\Install-CodexAdmin.ps1
pwsh -NoProfile -File .\scripts\Test-CodexAdminPublicProject.ps1
```

The installer creates a private site overlay from the synthetic examples but
does not enable recurring jobs, Windows autologon, remote access, or live
infrastructure mutations.

See [installation](docs/install.md), [architecture](docs/architecture.md),
[site overlays](docs/site-overlay.md), and [security policy](SECURITY.md).

## Safety model

Read-only discovery is the default. Destructive operations, secret-store or
permission changes, and any change that can reduce user or administrative
reachability require an exact, immediate confirmation. A scheduled or awakened
task never inherits a one-off approval.

## License

Licensed under the Apache License 2.0.
