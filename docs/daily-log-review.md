# Daily log review

The dedicated admin VM runs a read-only Homelab log review every day at 18:00
Europe/Berlin through the loopback-only Homelab Job Engine. The enabled job
`Homelab daily log review` executes the authoritative collector
`scripts/Invoke-HomelabDailyLogReview.ps1`.

## Safety boundary

The scheduled collector uses fixed read-only API, SSH, and Windows Event Log
queries. It cannot restart services, acknowledge alerts, install updates, change
configuration, clear logs, or repair a finding. Codex receives only a sanitized
local event bundle and runs with a read-only sandbox. Every remediation remains a
proposal until the user confirms it in a separate interactive task.

Credentials are obtained only from the current-user DPAPI vault where needed.
Tokens, passwords, cookies, authorization headers, OTP data, private keys, and
sensitive query parameters are removed before events are persisted or analyzed.
Raw remote logs are held only in process memory and are not written to disk.

Every enabled source is declared in `config/daily-log-review.json` with a stable
collector ID, system ID, adapter function and version, required/optional status,
read-only assertion, and timeout. The registry is validated fail-closed before
collection. Each adapter runs in an isolated PowerShell process; exceeding its
declared timeout terminates that collector and produces a sanitized coverage gap
instead of blocking the whole report.

## Autonomous triage and trend monitoring

The review reports only errors that are significant or actionable based on their
current impact, persistence, frequency, affected scope, and security relevance.
Isolated low-impact anomalies are stored as secret-free internal watch items for
30 days and do not change the overall or per-system status. Each subsequent run
compares new events with the active watch history. A watch item is promoted to a
finding when it recurs across review days, becomes more frequent, affects more
systems, or develops a meaningful operational or security impact.

The report shows the number of internal watch items but omits their individual
details until they cross the reporting threshold. If the trend history cannot be
loaded, that absence is a coverage gap and the run must not describe an anomaly as
non-recurring.

## Fixed report presentation

Every generated Markdown and HTML report uses this order:

1. Title, overall status, finding count, watch count, source coverage, and repair count.
2. System overview as the first report section.
3. Short conclusion.
4. Significant or actionable findings.
5. Compact internal-watch trend counts without individual watch details.
6. Confirmed successful or healthy events.
7. Source coverage and explicit coverage gaps.
8. Run details and the read-only audit statement.

Statuses, severities, and trends are displayed with concise German labels. Every
finding explains why it crossed the reporting threshold. This presentation order
is part of the durable Scheduled workflow and must not be rearranged ad hoc.

## Coverage

- Proxmox: node journal, recent PVE tasks, node status, storage status, QEMU and
  LXC state.
- Home Assistant: Core, Supervisor, host, and HAOS warning/error logs plus the
  minute-by-minute, correlated availability history for the external
  `https://home-automation.example.invalid/` route and the internal
  `http://192.0.2.20:8123/` reference endpoint. A missing or older-than-three-
  minutes availability sample is reported as a coverage gap. External failures
  also trigger secret-free DNS, public TCP/443, and direct local reverse-proxy
  diagnostics so the next report can identify whether the failure occurred
  before Nginx or on the local proxy/upstream path. Only schema-2 endpoint
  measurements with `probe_valid=true` count as availability evidence. Probe
  engine failures and recognized legacy transport artifacts become explicit
  monitor coverage gaps rather than false outage findings.
- Nginx Proxy Manager: `npm` and `openresty` service journal plus current proxy
  error logs.
- UniFi Dream Machine: system journal and selected Network, WAN, PoE, DNS,
  threat, reverse-proxy, database, and message-broker warning/error logs.
- Admin VM: Windows System, Application, Task Scheduler, and Microsoft Defender
  warning/error events.
- Public WireGuard relay: strict-host-key read-only SSH checks for WireGuard,
  nftables syntax, service state, handshake freshness, and warning/error journal
  entries.
- QNAP NAS: the structured read-only storage diagnostic, including RAID/storage
  issues and its explicit overall status. Serial numbers, shares, file contents,
  SMART tests, scrubs, and repairs remain excluded.
- Example game server: a non-persisting guest diagnostic summarized to command
  availability and explicit container/OOM/exit/fault signals. Raw guest and
  application logs are not retained by the daily adapter.
- Local control plane: the weekly quality-gate and monthly recovery status files
  are checked for valid schema, semantic success, and bounded freshness. The
  loopback Job Engine is also checked for the complete managed job set, unique
  enabled definitions, successful preflight, and failed or abandoned last runs.

Proxmox, Home Assistant (including availability), NPM, UniFi, Windows, public VPS provider,
and the local control-plane status are required sources. QNAP and Minecraft are
optional: a failure is shown as a coverage gap but does not by itself fail
required coverage.

Each run records secret-free findings and internal watch observations in the
Homelab SQLite knowledge base.
Reports are written to
`%LOCALAPPDATA%\CodexAdmin\homelab\reports`; `latest.md` and `latest.html` always
point to the newest completed run.

The sanitized collection snapshot is written exactly once per run and reused
unchanged for at most two AI-analysis attempts. If both attempts fail, the
collector cannot locate the local analyzer, or analysis is deliberately skipped,
the conservative fallback reports zero findings and zero watch items with
overall status `unknown`. Raw severity hints are never promoted into findings
without correlation.

Reports use same-directory atomic file replacement. A run-specific manifest and
`latest.manifest.json` record stage/attempt status, required coverage, artifact
byte lengths and SHA-256 hashes, plus an external manifest SHA-256 sidecar.
`latest.*` is rolled
back to the previous complete set if publication fails; unreferenced run-specific
files may remain as provenance but are not the latest successful report.

## Job Engine schedule

The active local job uses these settings:

- Name: `Homelab daily log review`
- Script: `scripts/Invoke-HomelabDailyLogReview.ps1`
- Working directory: `C:\Codex-Admin`
- Cron: `0 18 * * *`
- Timezone: `Europe/Berlin`
- Timeout: 3600 seconds
- Missed run: run once after the engine becomes available
- Overlap: skip a second instance
- Output capture: disabled
- Unattended classification: enabled only for the strict read-only workflow

The VM must be powered on and the dedicated Admin session must be available
because credentials use the current-user DPAPI vault. Windows automatic logon
and the shared Codex desktop logon task start the Job Engine after boot. The Job
Engine writes the report files locally and does not itself post a Codex chat
message. A separate active Codex heartbeat named
`Homelab-Tagesreport hier zustellen` runs daily at 18:10 local time and is
attached to the user's existing Homelab task. It never starts the collector a
second time. It verifies the current day's successful Job Engine audit record,
accepts only the matching fresh `latest.md`, and then publishes the complete
German report in that task. If the scheduled run is still active, it may wait in
short intervals until 18:30; a failed, incomplete, missing, or stale run is
reported as an explicit delivery or coverage gap.

The Codex app stores this heartbeat outside the repository under the current
user's automation state. The durable prompt in
`prompts/codex-scheduled-daily-log-review.md` remains a presentation reference,
not the active collector scheduler.

### Shared tools, knowledge, and results

The heartbeat runs in the same local project and Windows Admin profile as an
interactive System Admin task. It explicitly loads `homelab-admin`, repository
`AGENTS.md`, and `homelab_admin.context_bootstrap`. The globally configured MCP
server points to this repository's `mcp/homelab-admin/build/index.js`, so both
tasks use the same secret-free SQLite database at
`%LOCALAPPDATA%\CodexAdmin\homelab\homelab-ops.sqlite3`.

The delivery agent may use the same read-only context, statistics, knowledge,
incident-history, inventory, policy, selected system-context, TCP reachability,
shell, report, and Job Engine state tools used by the interactive agent. Because
the heartbeat is unattended, shared tool availability does not grant permission
to repair, reconfigure, restart, acknowledge, clear, or otherwise mutate
infrastructure. Such actions remain separate interactive work after explicit
confirmation.

All results remain available to an interactive System Admin task through three
shared channels: the complete user-facing report in the existing Codex task,
the local sanitized report files, and secret-free observations, incident history,
or maintenance state in the common knowledge database. Run
`scripts/Test-HomelabKnowledge.ps1` to detect drift in the automation status,
schedule, target task, project, skill, MCP/database reference, read-tool set,
result channels, or read-only boundary.

## Manual operation

Run a safe manual review:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\Invoke-HomelabDailyLogReview.ps1
```

Test collection and report generation without AI analysis:

```powershell
pwsh -ExecutionPolicy Bypass -File .\scripts\Invoke-HomelabDailyLogReview.ps1 -SkipAiAnalysis
```

For an isolated integration run that cannot replace production `latest.*`, pass
temporary `-RuntimeDirectory` and `-ReportDirectory` paths plus
`-SkipKnowledgeRecording`. The deterministic
unit suite is:

```powershell
Invoke-Pester -Script .\test\powershell\HomelabDailyReview.Tests.ps1
```

The job can be reviewed, disabled, edited, or run immediately in the local Job
Engine at `http://127.0.0.1:8770/`.
