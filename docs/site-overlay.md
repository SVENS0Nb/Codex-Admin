# Private site overlay

The default private configuration root is:

```text
%LOCALAPPDATA%\CodexAdmin\site
```

It mirrors selected repository paths:

```text
site\
  inventory\
    services.json
    systems.json
    interfaces.json
    service-catalog.json
    access-profiles.json
    capabilities.json
    dependencies.json
    maintenance.json
  config\
    daily-log-review.json
    job-definitions.json
```

`Install-CodexAdmin.ps1` creates these files from synthetic examples only when
they do not already exist. Existing deployment data is never overwritten.

Set `CODEX_ADMIN_SITE_ROOT` to an absolute path to use another location. The
location must remain outside the Git checkout. The PowerShell helper and MCP
server reject a site root inside the repository.

Secret values still do not belong in these JSON files. Use `credential_ref`
fields to refer to DPAPI vault records.
