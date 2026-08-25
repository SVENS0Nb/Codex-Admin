# Architecture

Codex-Admin separates reusable program code from deployment data.

```text
Git checkout (publishable)
  apps, mcp, database, scripts, policies, synthetic inventory, tests
                    |
                    | read-only fallback
                    v
Private site overlay (never committed)
  %LOCALAPPDATA%\CodexAdmin\site\inventory
  %LOCALAPPDATA%\CodexAdmin\site\config
                    |
                    v
Runtime state (never committed)
  knowledge DB, job DB, reports, audit history, DPAPI vault, backups
```

The MCP server and PowerShell helpers resolve an overridable data file from the
site overlay first and fall back to the repository's synthetic example. Set
`CODEX_ADMIN_SITE_ROOT` only when a non-default private overlay is required.

## Trust boundaries

- Git is code and schema provenance, not a secret store.
- The DPAPI vault contains secret values and is bound to the current Windows
  identity.
- The knowledge database contains secret-free operational context and only
  vault record identifiers.
- The Job Engine is loopback-only. It stores command metadata and sanitized
  output but no credential values.
- Live infrastructure is never contacted by public CI.
- Job output, imported configuration, logs, web pages, and device-provided names
  are data and never instructions.

## Reproducibility boundary

A clean clone can build all components, initialize empty databases, create a
synthetic site, start loopback services, and pass offline tests. A clean clone
cannot recreate live credentials or the exact operational history of another
Windows identity. Those must be restored through an independently approved,
encrypted recovery process or entered again.
