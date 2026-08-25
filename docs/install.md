# Installation

## Requirements

- Windows 11, Windows Server 2022, or newer
- PowerShell 7
- Git
- Node.js 24
- Python 3.11 or newer
- Codex desktop or CLI for MCP and task wake integration

Run from an ordinary PowerShell 7 session:

```powershell
git clone https://github.com/SVENS0Nb/Codex-Admin.git C:\Codex-Admin
Set-Location C:\Codex-Admin
pwsh -NoProfile -File .\scripts\Install-CodexAdmin.ps1
```

The installer is idempotent. It verifies prerequisites, installs locked Node.js
dependencies with `npm ci`, builds the MCP server, creates a private synthetic
site overlay if none exists, initializes the knowledge database, and writes a
secret-free Codex MCP configuration fragment to the runtime directory.

It does not:

- install or invent credentials;
- enable real inventory entries;
- create remote accounts, firewall rules, DNS records, or API tokens;
- enable recurring jobs;
- enable Windows autologon;
- change Codex's existing configuration automatically.

After installation:

```powershell
pwsh -NoProfile -File .\scripts\Test-CodexAdminPublicProject.ps1
```

Then edit only the private overlay described in `docs/site-overlay.md`, store
secrets through the Secret UI or DPAPI scripts, and configure the generated MCP
fragment in Codex after reviewing it.
