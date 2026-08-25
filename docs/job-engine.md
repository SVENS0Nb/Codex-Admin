# Homelab Job Engine

The Homelab Job Engine is a loopback-only scheduler for small background jobs
and scripts on the dedicated Codex admin VM.

Open it locally at:

    http://127.0.0.1:8770/

The engine starts when the dedicated `Admin` user signs in. The existing task
`CodexAdmin - Codex Desktop Autostart` invokes `scripts/Start-CodexDesktop.ps1`,
which first calls `scripts/Ensure-HomelabJobEngine.ps1` and then starts Codex.
`Start-HomelabJobEngine.cmd` uses the same idempotent starter for manual use.

## Supported jobs

- PowerShell `.ps1` files through PowerShell 7;
- executable programs through an absolute path and an argument array;
- five-field cron expressions in a named IANA timezone;
- `@hourly`, `@daily`, `@weekly`, and `@monthly` shortcuts;
- manual execution, per-job timeouts, overlap protection, missed-run handling,
  bounded optional output capture, 30-day recurring-job history, and permanent
  sanitized audit results for transient jobs.
- one-time jobs with an exact execution time and automatic removal from the
  active registry after completion;
- immediately started, bounded active tests that remain visible in the UI only
  while they run and retain their sanitized result in the audit history.

## One-time jobs and active tests

Every background test started by an agent must be registered with the Job
Engine. Use `scripts/Register-HomelabTransientJob.ps1`; do not edit the SQLite
database directly. The helper obtains the loopback session and CSRF token and
accepts only absolute local command paths. Examples:

    .\scripts\Register-HomelabTransientJob.ps1 -Mode ActiveTest `
      -Name 'Short read-only test' -CommandPath .\scripts\ReadOnlyTest.ps1 `
      -TimeoutSeconds 1800

    .\scripts\Register-HomelabTransientJob.ps1 -Mode OneTime `
      -Name 'One-time collection' -CommandPath .\scripts\Collector.ps1 `
      -ScheduledAt '2026-08-23T20:00:00+02:00'

When an agent creates a `OneTime` job, the helper binds it to the current Codex
task by default. No thread identifier needs to be copied or entered manually.
After the process finishes, fails, times out, or is skipped by the misfire
policy, the engine resumes that exact task and starts a continuation turn. Use
`-NoTaskWake` only for an explicitly fire-and-forget one-time job.

The continuation turn receives only secret-free job and run identifiers plus
status metadata. It retrieves sanitized details through:

    .\scripts\Get-HomelabJobRun.ps1 -RunId '<run-id>'

The task binding is stored only in the local ACL-protected Job Engine database
and is omitted from UI/API job representations. The audit history shows the
wake lifecycle (`Wartet`, `Reaktiviert`, `Fortgesetzt`, `Neuer Versuch`, or
`Fehlgeschlagen`) without exposing the thread identifier or the agent response.
Only one wake runs concurrently. Interrupted and transiently failed wakeups are
retried with bounded backoff, at most five attempts, and a successfully claimed
run cannot create a duplicate continuation.

The engine uses the pinned official `@openai/codex-sdk` package and the existing
signed-in Codex profile. It does not create or store an OpenAI API key. The
helper maps the current Codex filesystem permission profile to the wake turn;
the approval policy is always non-interactive. This preserves tool availability
but never carries forward a one-time user approval. The deterministic wake
prompt explicitly reloads `homelab-admin`, reads the sanitized run result, and
keeps all destructive, reachability, credential, permission, daily-remediation,
and physical-security confirmation gates intact.

Codex Desktop may omit `CODEX_PERMISSION_PROFILE` when this dedicated VM runs
with its configured disabled/unrestricted filesystem profile. In that specific
Desktop-originated case, the registration helper maps the wake turn to
`danger-full-access`; non-Desktop callers still fail closed when the profile is
missing or unknown.

The loopback API endpoints are `POST /api/active-tests` and
`POST /api/one-time-jobs`. Both force the unattended classification and
automatic archival. Active tests start immediately. One-time jobs execute once
at `scheduled_at`. After completion, timeout, or failure they disappear from
the active UI sections, while their run metadata remains in `Letzte
Ausführungen`. Definitions and output must remain secret-free.

"Automatic removal" means logical removal from every active registry and UI
section. The database keeps a hidden archived job record because the audit rows
refer to it for their name and provenance; physically deleting that row would
also delete its results. Archived `one_time` and `active_test` definitions and
their sanitized results are therefore never removed by automatic retention.
Only recurring-job run rows are pruned after 30 days.

## Audit history

The `Letzte Ausführungen` table uses a fixed maximum height of 560 pixels with
its own vertical scrollbar and a sticky header. The UI and API load at most 100
run records at a time. `Neuere 100` and `Ältere 100` navigate through the
retained history, while the center label shows the displayed range and total.
Requests beyond the last page are clamped to the final available page.

Arguments are passed directly to the process without a command shell. Put one
argument on each line in the UI. Do not place passwords, tokens, OTP seeds,
private keys, authorization headers, or other credential values in job names,
arguments, paths, descriptions, or output. The engine runs as the signed-in
`Admin` user and can access that user's current-user DPAPI profile. Scripts that
need credentials must retrieve them only at runtime by their configured secret
reference and must not print, persist, or pass their values in command-line
arguments.

## Safety boundary

A schedule can be activated only after the job is explicitly marked as safe for
unattended execution. This classification is an operator assertion; the engine
cannot prove what an arbitrary script does.

Never schedule the following without a separate approved workflow:

- destructive deletes or overwrites;
- gateway, management IP, VLAN, firewall, DNS authority, remote access, MFA,
  credential, permission, API-key, or secret-store changes;
- repairs or remediation proposed by the daily 18:00 log review;
- physical-security actions.

Use manual-only jobs for scripts that need an immediate decision. The UI asks
again before a manual start, but Homelab policy still governs the action.

### Deterministic preflight manifest

Job Engine 1.8 pins every registered command and every explicitly declared
runtime dependency by SHA-256. Its secret-free safety state contains
`safety_classification`, required DPAPI credential references, required
endpoints, expected absolute artifacts, the task-wake condition, and a structured
dependency manifest. Registration and every run perform preflight checks. A
changed or missing dependency, path outside the approved working tree, relative
artifact path, or `manual_only` classification blocks unattended execution
before the command starts.

Expected artifacts are verified again after a successful process exit. A
conditional one-time job can emit a final sanitized JSON signal with
`wakeAgent=false`; only that explicit signal suppresses task continuation.
Preflight failure remains visible in audit history and can wake the bound task
for analysis, but it never authorizes a repair or configuration change.

### Versioned recurring-job definitions

`config/job-definitions.json` is the source of truth for Homelab-owned recurring
jobs. It contains no credential values: access requirements refer to stable
profile IDs, and `scripts/Sync-HomelabRecurringJobs.ps1` resolves only their
DPAPI record identifiers when constructing the local API request. Each job also
declares `dependency_paths`. Individual relative paths are preferred;
`@repository-files` is the explicit scope for the complete tracked and unignored
repository when a gate or backup genuinely depends on all of it. The synchronizer
rejects path escapes, resolves and hashes every dependency, and always includes
the executable command. Run it without parameters for a read-only, hash-bearing
plan. `-Apply` additively creates or updates the selected definitions and
immediately runs the Engine preflight; it never deletes an unmanaged or archived
job.

The versioned managed set includes the Home Assistant availability monitor,
daily review, UniFi security archive, weekly quality gate, and monthly
control-plane recovery point. A definition is not proof that its runtime job is
active: inspect the loopback Engine state and preflight. Monitoring targets that are supposed to
detect an outage are deliberately
not hard endpoint preflight requirements: their failure must create evidence or
a coverage gap, not suppress the diagnostic itself. The UniFi archive does have
a mandatory SSH access profile and endpoint because no useful collection is
possible without them.

The weekly and monthly jobs call small wrappers that atomically publish bounded,
secret-free status files. The recovery wrapper excludes the encrypted vault by
default, fails closed when the repository is dirty, restore-tests every backup,
and never prunes old copies.

The Job Engine database is upgraded by contiguous, numbered SQL migrations in
`apps/job-engine/migrations`. Each migration runs in its own transaction and is
recorded in `schema_migrations` plus `PRAGMA user_version`. A known legacy
schema is adopted losslessly once; incomplete legacy signatures and future
schema versions fail closed. Backup verification requires the exact supported
schema version.

## Scheduling behavior

Cron fields are minute, hour, day of month, month, and weekday. Day-of-month and
weekday use common cron OR behavior when both are restricted. The default
timezone is `Europe/Berlin`.

If the VM was unavailable at the planned time, `run_once` executes the job once
after startup. `skip` drops a missed run after the five-minute grace period.
Only one instance of a job runs at a time, and at most three different jobs run
in parallel. Job processes are terminated with their child process tree after
the configured timeout.

## Home Assistant availability monitor

The enabled job `Home Assistant availability (external/internal)` runs
`scripts/Invoke-HomeAssistantAvailabilityProbe.ps1` every minute in
`Europe/Berlin`. It performs unauthenticated, read-only GET probes against the
external route and the internal Home Assistant endpoint concurrently through
separate certificate-validating `curl.exe` processes. A monitor/tool failure is
recorded as `probe_error` with `probe_valid=false`; it is a coverage failure and
is never counted as a Home Assistant outage. No response body, header, cookie,
credential, or raw exception text is retained.

Each run appends one secret-free JSONL record to:

    %LOCALAPPDATA%\CodexAdmin\homelab\availability\home-assistant-availability-YYYY-MM-DD.jsonl

The correlation distinguishes `both_online`, `external_path_failure`,
`both_unavailable`, and `internal_reference_failure`. Daily files bound the size
of each individual log; records are not automatically deleted. The daily 18:00
review summarizes this history, detects missing samples, and treats stale or
absent monitoring data as a coverage gap.

After an external failure, the probe now performs an immediate read-only,
secret-free diagnostic follow-up. It records only DNS outcome and address count,
public TCP/443 outcome, and a certificate-validating direct local
Nginx-to-Home-Assistant HTTP status. It never retains resolved addresses,
headers, bodies, cookies, authorization data, or exception text. This separates
failures before Nginx from local reverse-proxy or Home Assistant failures on the
next recurrence without changing routing or service configuration.

## UniFi security event archive

The enabled job `UniFi security event archive` runs
`scripts/Sync-UniFiSecurityLog.ps1` every minute. It pulls only sanitized
IDS/IPS metadata from the Primary Site Dream Machine over the existing SSH
access path and writes to the separate database documented in
`docs/unifi-security-logging.md`. It does not enable a receiver, change the
Dream Machine, or capture packet and HTTP payload data.

## Daily Homelab log review

The enabled job `Homelab daily log review` runs
`scripts/Invoke-HomelabDailyLogReview.ps1` at `0 18 * * *` in `Europe/Berlin`.
It is classified as safe for unattended execution only because the collector is
strictly limited to reading, sanitizing, analyzing, reporting, and recording
secret-free observations. It must never remediate a finding.

The job uses a 3600-second timeout, overlap policy `skip`, and missed-run policy
`run_once`. Output capture is disabled. The script writes `latest.md` and
`latest.html` below `%LOCALAPPDATA%\CodexAdmin\homelab\reports`; the Job Engine
does not itself deliver the report as a Codex chat message.

Delivery into Codex is handled independently by the active thread heartbeat
`Homelab-Tagesreport hier zustellen` at 18:10 local time. The heartbeat is bound
to the user's existing Homelab task, does not rerun the collector, verifies the
current day's Job Engine audit and report freshness, and publishes either the
complete German report or a concrete delivery/coverage gap. This separation
keeps report generation deterministic in the local Job Engine while making the
result visible in the agreed Codex task.

The delivery heartbeat and interactive System Admin tasks share the same local
project, `homelab-admin` skill, globally configured `homelab_admin` MCP server,
and secret-free SQLite knowledge database. The heartbeat publishes its full
user-facing result to the bound task and leaves sanitized machine-readable
evidence in the existing report and knowledge stores. Its unattended execution
is limited to read-only infrastructure access even though the shared environment
exposes a broader interactive admin toolset.

## Storage and recovery

Runtime state is stored outside Git at:

    %LOCALAPPDATA%\CodexAdmin\job-engine\jobs.sqlite3

The directory ACL grants access only to the signed-in Windows user and SYSTEM.
The database contains job definitions and sanitized run metadata, never
credentials. SQLite uses WAL mode and marks interrupted executions as
`abandoned` on restart. Schema version 5 stores the per-job dependency manifest;
numbered migrations make every prior supported state reproducible and testable.

Create a consistent online backup while the engine remains open with:

    node .\apps\job-engine\backup.mjs backup

The command uses SQLite's online backup API, validates integrity and foreign
keys, and lists backups beyond the retention target without deleting them.
Verify a backup or perform a non-destructive temporary restore test with:

    node .\apps\job-engine\backup.mjs verify <absolute-backup-path>
    node .\apps\job-engine\backup.mjs restore-test <absolute-backup-path>

Never restore over the live database while the supervisor is running. A live
restore, database replacement, backup deletion, or engine restart requires the
applicable confirmation and recovery workflow.

## Windows execution identity

The shared logon task uses the dedicated `Admin` identity after interactive
sign-in. Windows automatically signs this dedicated account in after boot, so
the engine becomes available without a manual login. Scheduled programs inherit
the Admin user's profile and current-user DPAPI access. The unattended-safety
classification remains mandatory because jobs can run without further
interaction once the user session exists.

The obsolete separate task `CodexAdmin - Homelab Job Engine` is disabled. The
single supported startup path is the existing `CodexAdmin - Codex Desktop
Autostart` task, which calls the idempotent engine bootstrap before starting
Codex. This avoids competing supervisors opening the same SQLite database.

To reinstall or repair autostart:

    .\scripts\Install-HomelabJobEngineAutostart.ps1

To stop the engine, end its hidden PowerShell supervisor. To remove Job Engine
autostart while retaining Codex autostart, remove the ensure call from
`scripts/Start-CodexDesktop.ps1`; preserve the SQLite file if job definitions or
history are still needed.
