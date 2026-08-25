# Homelab knowledge base

The operational knowledge base is a secret-free SQLite database at:

    %LOCALAPPDATA%\CodexAdmin\homelab\homelab-ops.sqlite3

The schema and all authoritative seed data are versioned in this repository.
The live database is local generated state and is not committed.

## Purpose

The database gives every Codex task a consistent view of the administrator role,
systems, interfaces, dependencies, access references, verified capabilities,
facts, time-bound observations, changes, incidents, maintenance, decisions, and
runbooks. It never replaces live verification for time-sensitive information.

## Source order

1. Current live state verified through an API, SSH, PowerShell, or an approved UI.
2. Structured inventory and verified database records.
3. Versioned runbooks and change history.
4. Local Codex memories.
5. Chat recollection or inference.

When sources conflict, preserve the evidence, mark the older claim superseded or
disputed, and verify the live state before a consequential change.

## Record selection

- Use a **fact** for a stable claim such as a VMID, hardware identifier, or
  configured relationship.
- Use a **system, interface, service, or dependency** for the durable
  infrastructure map and the functions each managed system provides.
- Use an **observation** for reachability, health, certificate, version, backup,
  or access checks that expire.
- Use a **change** only after productive work has a result, verification, and
  rollback state.
- Use an **incident** for a diagnosed problem lifecycle. Preserve symptoms,
  root cause, remediation, prevention, status transitions, and verification in
  immutable events so later agents can reuse the resolution.
- Use **maintenance** for work that is due, recurring, completed, or deferred.
- Use a **decision** or versioned runbook for durable operational reasoning.

Every new claim requires a source, observation time, and confidence. Add a
validity period whenever the claim can become stale.

The structured infrastructure source consists of:

- `inventory/systems.json` for managed hosts, guests, storage, networks, and
  controller-managed infrastructure devices;
- `inventory/interfaces.json` for secret-free addresses and management paths;
- `inventory/service-catalog.json` for system functions and service roles;
- `inventory/dependencies.json` for hosting, storage, routing, proxying, and
  management relationships.

`context_bootstrap` includes the complete service catalogue, and
`system_context_get` returns the services attached to one selected system.

## Secret boundary

Passwords, tokens, cookies, OTP values, recovery codes, private keys, and
authorization headers are forbidden. Only a DPAPI Secret UI record identifier
may be stored in `credential_ref`. The database rejects common credential
material patterns in controlled write functions.

## Agent start and fallback

At the start of Homelab work, call the MCP tool `context_bootstrap`. If the MCP
server is unavailable, run:

    .\scripts\Get-HomelabContext.ps1

Use `knowledge_freshness_report` before relying on old data and
`system_context_get` before changing a specific system. Search prior symptoms
and resolutions with `knowledge_search` or `incident_search` before starting a
new diagnosis. Record durable problem lifecycles with `incident_record` and
operational choices with `decision_record`.

If the MCP process is temporarily unavailable, use the built CLI from
`mcp/homelab-admin`: `node build/cli.js search "<symptoms>" 10` or
`node build/cli.js incident-search "<symptoms>" 10`. Search terms must remain
secret-free, just like every other knowledge-database input.

The freshness report evaluates only the newest observation for each system and
kind. Expired historical rows remain as evidence but no longer create false
staleness warnings after a current replacement has been recorded.

Normal startup uses bounded aggregate SQL projections for role, policy, counts,
freshness summary, active task contracts, learning attention, and the most
relevant state. It does not first materialize the complete access, capability,
service, or dependency catalogs. Broad audits can request `context full`;
bounded multi-system work should use batch system/service reads. This prevents
every new task from spending context on the entire inventory.

`task_contracts` preserve secret-free objective, constraints, approvals,
evidence, next action, and completion criteria across a reboot or task wake. New
contracts are bound server-side to the MCP process's validated `CODEX_THREAD_ID`;
tool callers cannot target another task, and updates from a different bound task
are rejected. `learning_candidates` stage proposed reusable knowledge until an
interactive review promotes or rejects it. New candidates receive a 14-day
`review_due_at` deadline; compact bootstrap flags those due within three days and
those overdue. Neither table stores credentials or grants new authority, and
neither an automatic wake nor a learning candidate can inherit a one-off
confirmation.

Validate the complete global-instruction, skill, project, MCP, SQLite, ACL,
backup, memory-setting, and scheduled-maintenance chain with:

    .\scripts\Test-HomelabKnowledge.ps1

## Maintenance and backup

The Windows task `CodexAdmin - Homelab Knowledge Maintenance` runs at user logon
and daily at 03:17 while the dedicated Admin user is signed in. It synchronizes
versioned sources, records TCP observations,
checks SQLite integrity, and creates a retained local backup under:

    %LOCALAPPDATA%\CodexAdmin\homelab\backups

The configured retention value is a target, not deletion authority. Maintenance
reports excess backups as prune candidates; deleting any backup still requires
the standalone confirmation defined by project policy.

The database does not contain secrets, but its directory is restricted to the
current Windows user and SYSTEM. By explicit user decision, repository and
database backups remain on this dedicated Proxmox admin VM. This is a deliberate
single-failure-domain tradeoff; no external repository or off-host backup is
created automatically.

Authenticated administrative access is intentionally not tested by the daily
task because those checks temporarily use protected credentials. Run the
secret-safe access check and update all related profiles and capabilities with:

    .\scripts\Update-HomelabAccessKnowledge.ps1

The bootstrap freshness report flags access profiles after seven days so a new
agent knows when this verification is due.
