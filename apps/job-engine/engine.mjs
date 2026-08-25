import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, statSync } from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import {
  normalizeSafetyManifest,
  parseWakeSignal,
  preflightJob,
  sha256File,
  verifyExpectedArtifacts,
} from "./safety.mjs";
import { migrateJobEngineDatabase } from "./migrations.mjs";

const MINUTE_MS = 60_000;
const MAX_OUTPUT_BYTES = 65_536;
const MAX_NEXT_SEARCH_MINUTES = 60 * 24 * 366 * 5;
const formatterCache = new Map();

const MONTH_NAMES = new Map([
  ["jan", 1], ["feb", 2], ["mar", 3], ["apr", 4], ["may", 5], ["jun", 6],
  ["jul", 7], ["aug", 8], ["sep", 9], ["oct", 10], ["nov", 11], ["dec", 12],
]);
const WEEKDAY_NAMES = new Map([
  ["sun", 0], ["mon", 1], ["tue", 2], ["wed", 3], ["thu", 4], ["fri", 5], ["sat", 6],
]);
const WEEKDAY_FROM_FORMAT = new Map([
  ["Sun", 0], ["Mon", 1], ["Tue", 2], ["Wed", 3], ["Thu", 4], ["Fri", 5], ["Sat", 6],
]);
const CRON_MACROS = new Map([
  ["@hourly", "0 * * * *"],
  ["@daily", "0 0 * * *"],
  ["@weekly", "0 0 * * 0"],
  ["@monthly", "0 0 1 * *"],
]);

function isoNow() {
  return new Date().toISOString();
}

function normalizeCron(expression) {
  const value = String(expression || "").trim().toLowerCase();
  return CRON_MACROS.get(value) || value;
}

function parseValue(raw, names, minimum, maximum, isWeekday) {
  const lower = String(raw).toLowerCase();
  const named = names?.get(lower);
  const value = named ?? Number.parseInt(lower, 10);
  if (!Number.isInteger(value)) throw new Error(`Ungültiger Cron-Wert: ${raw}`);
  const normalized = isWeekday && value === 7 ? 0 : value;
  if (normalized < minimum || normalized > maximum) {
    throw new Error(`Cron-Wert ${raw} liegt außerhalb von ${minimum}-${maximum}.`);
  }
  return normalized;
}

function parseField(raw, minimum, maximum, names, isWeekday = false) {
  const values = new Set();
  const wildcard = raw === "*";
  for (const item of raw.split(",")) {
    if (!item) throw new Error("Leerer Cron-Listeneintrag.");
    const [base, stepRaw, extra] = item.split("/");
    if (extra !== undefined) throw new Error(`Ungültiger Cron-Schritt: ${item}`);
    const step = stepRaw === undefined ? 1 : Number.parseInt(stepRaw, 10);
    if (!Number.isInteger(step) || step < 1 || step > maximum - minimum + 1) {
      throw new Error(`Ungültige Cron-Schrittweite: ${item}`);
    }

    let start;
    let end;
    if (base === "*") {
      start = minimum;
      end = maximum;
    } else if (base.includes("-")) {
      const parts = base.split("-");
      if (parts.length !== 2) throw new Error(`Ungültiger Cron-Bereich: ${item}`);
      start = parseValue(parts[0], names, minimum, maximum, isWeekday);
      end = parseValue(parts[1], names, minimum, maximum, isWeekday);
      if (start > end) throw new Error(`Cron-Bereich darf nicht rückwärts laufen: ${item}`);
    } else {
      start = parseValue(base, names, minimum, maximum, isWeekday);
      end = start;
      if (stepRaw !== undefined) throw new Error(`Schrittweite benötigt * oder einen Bereich: ${item}`);
    }

    for (let value = start; value <= end; value += step) values.add(value);
  }
  if (values.size === 0) throw new Error(`Leeres Cron-Feld: ${raw}`);
  return { values, wildcard };
}

export function parseCron(expression) {
  const normalized = normalizeCron(expression);
  const fields = normalized.split(/\s+/);
  if (fields.length !== 5) {
    throw new Error("Cron benötigt fünf Felder: Minute Stunde Tag Monat Wochentag.");
  }
  return {
    expression: normalized,
    minute: parseField(fields[0], 0, 59),
    hour: parseField(fields[1], 0, 23),
    day: parseField(fields[2], 1, 31),
    month: parseField(fields[3], 1, 12, MONTH_NAMES),
    weekday: parseField(fields[4], 0, 6, WEEKDAY_NAMES, true),
  };
}

function formatterFor(timezone) {
  if (!formatterCache.has(timezone)) {
    const formatter = new Intl.DateTimeFormat("en-US-u-ca-gregory", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      weekday: "short",
      hourCycle: "h23",
    });
    formatter.format(new Date());
    formatterCache.set(timezone, formatter);
  }
  return formatterCache.get(timezone);
}

function zonedFields(date, timezone) {
  const parts = Object.fromEntries(
    formatterFor(timezone).formatToParts(date)
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, part.value]),
  );
  return {
    minute: Number(parts.minute),
    hour: Number(parts.hour),
    day: Number(parts.day),
    month: Number(parts.month),
    weekday: WEEKDAY_FROM_FORMAT.get(parts.weekday),
  };
}

export function matchesCron(parsedOrExpression, date, timezone = "Europe/Berlin") {
  const parsed = typeof parsedOrExpression === "string" ? parseCron(parsedOrExpression) : parsedOrExpression;
  const fields = zonedFields(date, timezone);
  const ordinaryMatch = parsed.minute.values.has(fields.minute) &&
    parsed.hour.values.has(fields.hour) && parsed.month.values.has(fields.month);
  if (!ordinaryMatch) return false;

  const dayMatch = parsed.day.values.has(fields.day);
  const weekdayMatch = parsed.weekday.values.has(fields.weekday);
  const calendarMatch = parsed.day.wildcard && parsed.weekday.wildcard ? true :
    parsed.day.wildcard ? weekdayMatch :
      parsed.weekday.wildcard ? dayMatch : dayMatch || weekdayMatch;
  return calendarMatch;
}

export function nextOccurrence(expression, timezone = "Europe/Berlin", after = new Date()) {
  formatterFor(timezone);
  const parsed = parseCron(expression);
  let timestamp = Math.floor(after.getTime() / MINUTE_MS) * MINUTE_MS + MINUTE_MS;
  for (let index = 0; index < MAX_NEXT_SEARCH_MINUTES; index += 1, timestamp += MINUTE_MS) {
    const candidate = new Date(timestamp);
    if (matchesCron(parsed, candidate, timezone)) return candidate;
  }
  throw new Error("Kein Cron-Termin innerhalb der nächsten fünf Jahre gefunden.");
}

function cleanString(value, maximumLength) {
  return String(value ?? "").trim().slice(0, maximumLength);
}

function parseArguments(value) {
  const array = Array.isArray(value) ? value : [];
  if (array.length > 64) throw new Error("Höchstens 64 Argumente sind erlaubt.");
  return array.map((item) => {
    const text = String(item);
    if (text.includes("\0")) throw new Error("Argumente dürfen keine Nullzeichen enthalten.");
    if (text.length > 4096) throw new Error("Ein Argument ist zu lang.");
    return text;
  });
}

export function validateJobInput(input, existing = null) {
  const source = input && typeof input === "object" ? input : {};
  const name = cleanString(source.name ?? existing?.name, 120);
  if (!name) throw new Error("Ein Jobname ist erforderlich.");

  const rawJobType = cleanString(source.job_type ?? existing?.job_type ?? "recurring", 30);
  const jobType = rawJobType === "cron" ? "recurring" : rawJobType === "background_test" ? "active_test" : rawJobType;
  if (!["recurring", "one_time", "active_test"].includes(jobType)) {
    throw new Error("Jobtyp muss recurring, one_time oder active_test sein.");
  }

  const schedule = cleanString(source.schedule ?? existing?.schedule ?? "0 * * * *", 120);
  const timezone = cleanString(source.timezone ?? existing?.timezone ?? "Europe/Berlin", 100);
  parseCron(schedule);
  formatterFor(timezone);

  const scheduledAtRaw = source.scheduled_at ?? existing?.scheduled_at ?? null;
  const scheduledAt = scheduledAtRaw ? new Date(scheduledAtRaw) : null;
  if (jobType === "one_time" && (!scheduledAt || Number.isNaN(scheduledAt.getTime()))) {
    throw new Error("Ein einmaliger Job benötigt einen gültigen scheduled_at-Zeitpunkt.");
  }

  const commandType = cleanString(source.command_type ?? existing?.command_type ?? "powershell", 30);
  if (!["powershell", "executable"].includes(commandType)) {
    throw new Error("Befehlstyp muss powershell oder executable sein.");
  }

  const commandRaw = cleanString(source.command_path ?? existing?.command_path, 2048);
  if (!commandRaw) throw new Error("Ein absoluter Skript- oder Programmpfad ist erforderlich.");
  const commandPath = path.resolve(commandRaw);
  if (!path.isAbsolute(commandPath) || !existsSync(commandPath) || !statSync(commandPath).isFile()) {
    throw new Error("Der absolute Skript- oder Programmpfad wurde nicht gefunden.");
  }
  if (commandType === "powershell" && path.extname(commandPath).toLowerCase() !== ".ps1") {
    throw new Error("PowerShell-Jobs benötigen eine .ps1-Datei.");
  }

  const workingRaw = cleanString(source.working_directory ?? existing?.working_directory ?? path.dirname(commandPath), 2048);
  const workingDirectory = path.resolve(workingRaw);
  if (!path.isAbsolute(workingDirectory) || !existsSync(workingDirectory) || !statSync(workingDirectory).isDirectory()) {
    throw new Error("Das Arbeitsverzeichnis wurde nicht gefunden.");
  }

  const timeoutSeconds = Number(source.timeout_seconds ?? existing?.timeout_seconds ?? 900);
  if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 5 || timeoutSeconds > 86_400) {
    throw new Error("Das Zeitlimit muss zwischen 5 und 86400 Sekunden liegen.");
  }

  const enabled = Boolean(source.enabled ?? existing?.enabled ?? false);
  const unattended = Boolean(source.unattended ?? existing?.unattended ?? false);
  if (enabled && !unattended) {
    throw new Error("Ein Cron-Job darf nur aktiviert werden, wenn er ausdrücklich als unbeaufsichtigt zulässig markiert ist.");
  }
  const commandSha256 = sha256File(commandPath);
  const dependencyManifest = source.dependency_manifest ?? existing?.dependency_manifest ?? [{
    path: commandPath,
    sha256: commandSha256,
    role: "command",
  }];
  const manifest = normalizeSafetyManifest(
    { ...source, dependency_manifest: dependencyManifest },
    existing,
    workingDirectory,
    commandPath,
  );
  const normalizedCommand = process.platform === "win32" ? commandPath.toLowerCase() : commandPath;
  const commandDependency = manifest.dependency_manifest.find((dependency) => {
    const candidate = process.platform === "win32" ? dependency.path.toLowerCase() : dependency.path;
    return candidate === normalizedCommand && dependency.role === "command";
  });
  if (!commandDependency || commandDependency.sha256 !== commandSha256) {
    throw new Error("Das Abhängigkeitsmanifest muss den aktuellen Befehls-Hash enthalten.");
  }
  if (unattended && manifest.safety_classification === "manual_only") {
    throw new Error("Ein unbeaufsichtigter Job benötigt die Sicherheitsklassifizierung read_only oder local_state_write.");
  }

  const overlapPolicy = cleanString(source.overlap_policy ?? existing?.overlap_policy ?? "skip", 20);
  const misfirePolicy = cleanString(source.misfire_policy ?? existing?.misfire_policy ?? "run_once", 20);
  if (overlapPolicy !== "skip") throw new Error("Aktuell wird nur die Überschneidungsregel skip unterstützt.");
  if (!["skip", "run_once"].includes(misfirePolicy)) throw new Error("Ungültige Nachholregel.");

  const wakeEnabled = Boolean(source.wake_enabled ?? existing?.wake_enabled ?? false);
  const wakeThreadId = cleanString(source.wake_thread_id ?? existing?.wake_thread_id, 80);
  const wakeSandboxMode = cleanString(source.wake_sandbox_mode ?? existing?.wake_sandbox_mode ?? "read-only", 40);
  const wakeApprovalPolicy = cleanString(source.wake_approval_policy ?? existing?.wake_approval_policy ?? "never", 40);
  const wakeCondition = cleanString(source.wake_condition ?? existing?.wake_condition ?? "always", 30);
  if (!["always", "on_signal"].includes(wakeCondition)) {
    throw new Error("Wake-Bedingung muss always oder on_signal sein.");
  }
  const wakeWorkingRaw = cleanString(
    source.wake_working_directory ?? existing?.wake_working_directory ?? workingDirectory,
    2048,
  );
  const wakeWorkingDirectory = wakeWorkingRaw ? path.resolve(wakeWorkingRaw) : null;
  if (wakeEnabled) {
    if (jobType !== "one_time") throw new Error("Eine Codex-Task-Reaktivierung ist nur für One-Time-Jobs zulässig.");
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(wakeThreadId)) {
      throw new Error("Für die Reaktivierung ist eine gültige Codex-Thread-ID erforderlich.");
    }
    if (!wakeWorkingDirectory || !existsSync(wakeWorkingDirectory) || !statSync(wakeWorkingDirectory).isDirectory()) {
      throw new Error("Das Arbeitsverzeichnis für die Codex-Reaktivierung wurde nicht gefunden.");
    }
    if (!["read-only", "workspace-write", "danger-full-access"].includes(wakeSandboxMode)) {
      throw new Error("Ungültiger Sandbox-Modus für die Codex-Reaktivierung.");
    }
    if (wakeApprovalPolicy !== "never") {
      throw new Error("Unbeaufsichtigte Codex-Reaktivierungen dürfen keine interaktiven Freigaben anfordern.");
    }
  }

  return {
    job_type: jobType,
    name,
    description: cleanString(source.description ?? existing?.description, 1000),
    schedule: parseCron(schedule).expression,
    timezone,
    command_type: commandType,
    command_path: commandPath,
    arguments: parseArguments(source.arguments ?? existing?.arguments),
    working_directory: workingDirectory,
    enabled,
    unattended,
    timeout_seconds: timeoutSeconds,
    overlap_policy: overlapPolicy,
    misfire_policy: misfirePolicy,
    capture_output: Boolean(source.capture_output ?? existing?.capture_output ?? false),
    scheduled_at: scheduledAt ? scheduledAt.toISOString() : null,
    auto_archive: Boolean(source.auto_archive ?? existing?.auto_archive ?? jobType !== "recurring"),
    wake_enabled: wakeEnabled,
    wake_thread_id: wakeEnabled ? wakeThreadId : null,
    wake_working_directory: wakeEnabled ? wakeWorkingDirectory : null,
    wake_sandbox_mode: wakeEnabled ? wakeSandboxMode : null,
    wake_approval_policy: wakeEnabled ? wakeApprovalPolicy : null,
    command_sha256: commandSha256,
    wake_condition: wakeEnabled ? wakeCondition : "always",
    ...manifest,
  };
}

function redactOutput(value) {
  return String(value || "")
    .replace(/-----BEGIN [^-]*(?:PRIVATE KEY|OPENSSH KEY)-----[\s\S]*?-----END [^-]*(?:PRIVATE KEY|OPENSSH KEY)-----/gi, "[REDACTED PRIVATE KEY]")
    .replace(/\b(Bearer|Basic|PVEAPIToken)\s+[A-Za-z0-9._~+/=-]+/gi, "$1 [REDACTED]")
    .replace(/\b(password|passwd|token|api[_-]?key|secret|authorization|cookie)\b\s*[:=]\s*([^\s,;]+)/gi, "$1=[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[REDACTED JWT]")
    .slice(0, MAX_OUTPUT_BYTES);
}

export class JobStore {
  constructor(databasePath) {
    mkdirSync(path.dirname(databasePath), { recursive: true });
    this.databasePath = databasePath;
    this.db = new DatabaseSync(databasePath);
    this.db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;");
    this.migrate();
  }

  migrate() {
    migrateJobEngineDatabase(this.db);
    this.db.exec("UPDATE jobs SET job_type='recurring' WHERE job_type='cron'");
    this.db.exec("UPDATE jobs SET job_type='active_test',auto_archive=1 WHERE job_type='background_test'");
    for (const row of this.db.prepare("SELECT id,command_path FROM jobs WHERE command_sha256 IS NULL OR command_sha256='' ").all()) {
      try {
        if (existsSync(row.command_path) && statSync(row.command_path).isFile()) {
          this.db.prepare("UPDATE jobs SET command_sha256=? WHERE id=?").run(sha256File(row.command_path), row.id);
        }
      } catch {
        // The regular preflight records an unreadable command before execution.
      }
    }
    for (const row of this.db.prepare("SELECT id,command_path,command_sha256,dependency_manifest_json FROM jobs").all()) {
      if (row.dependency_manifest_json && row.dependency_manifest_json !== "[]") continue;
      try {
        if (existsSync(row.command_path) && statSync(row.command_path).isFile()) {
          const commandSha256 = row.command_sha256 || sha256File(row.command_path);
          const manifest = [{ path: path.resolve(row.command_path), sha256: commandSha256, role: "command" }];
          this.db.prepare("UPDATE jobs SET dependency_manifest_json=? WHERE id=?").run(JSON.stringify(manifest), row.id);
        }
      } catch {
        // The fail-closed preflight reports a missing or unreadable dependency.
      }
    }
    this.db.prepare("UPDATE runs SET status='abandoned', finished_at=?, error='Engine wurde während der Ausführung beendet.' WHERE status='running'")
      .run(isoNow());
    this.db.prepare(`UPDATE runs SET wake_status='retrying',wake_next_attempt_at=?,wake_finished_at=NULL,
      wake_error='Codex-Reaktivierung wurde durch einen Engine-Neustart unterbrochen.' WHERE wake_status='running'`).run(isoNow());
    this.db.prepare(`UPDATE jobs SET archived=1,enabled=0,next_run_at=NULL,updated_at=?
      WHERE job_type IN ('one_time','active_test') AND last_status IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM runs WHERE runs.job_id=jobs.id AND runs.status='running')`).run(isoNow());
  }

  close() {
    this.db.close();
  }

  rowToJob(row) {
    if (!row) return null;
    return {
      ...row,
      arguments: JSON.parse(row.arguments_json || "[]"),
      required_credential_refs: JSON.parse(row.required_credential_refs_json || "[]"),
      required_endpoints: JSON.parse(row.required_endpoints_json || "[]"),
      expected_artifacts: JSON.parse(row.expected_artifacts_json || "[]"),
      dependency_manifest: JSON.parse(row.dependency_manifest_json || "[]"),
      preflight: row.preflight_json ? JSON.parse(row.preflight_json) : null,
      wake_context: row.wake_context_json ? JSON.parse(row.wake_context_json) : null,
      enabled: Boolean(row.enabled),
      unattended: Boolean(row.unattended),
      capture_output: Boolean(row.capture_output),
      auto_archive: Boolean(row.auto_archive),
      archived: Boolean(row.archived),
      wake_enabled: Boolean(row.wake_enabled),
      arguments_json: undefined,
      required_credential_refs_json: undefined,
      required_endpoints_json: undefined,
      expected_artifacts_json: undefined,
      dependency_manifest_json: undefined,
      preflight_json: undefined,
      wake_context_json: undefined,
    };
  }

  listJobs() {
    return this.db.prepare("SELECT * FROM jobs WHERE job_type='recurring' AND archived=0 ORDER BY name COLLATE NOCASE").all().map((row) => this.rowToJob(row));
  }

  listOneTimeJobs() {
    return this.db.prepare("SELECT * FROM jobs WHERE job_type='one_time' AND archived=0 ORDER BY scheduled_at").all().map((row) => this.rowToJob(row));
  }

  listActiveTests() {
    return this.db.prepare("SELECT * FROM jobs WHERE job_type='active_test' AND archived=0 ORDER BY created_at DESC").all().map((row) => this.rowToJob(row));
  }

  listJobNames() {
    return Object.fromEntries(this.db.prepare("SELECT id,name FROM jobs").all().map((row) => [row.id, row.name]));
  }

  getJob(id) {
    return this.rowToJob(this.db.prepare("SELECT * FROM jobs WHERE id=?").get(id));
  }

  runPreflight(jobId, options = {}) {
    const job = this.getJob(jobId);
    if (!job) throw new Error("Job wurde nicht gefunden.");
    const result = preflightJob(job, options);
    this.db.prepare("UPDATE jobs SET preflight_status=?,preflight_checked_at=?,preflight_json=?,updated_at=? WHERE id=?")
      .run(result.ok ? "passed" : "failed", result.checked_at, JSON.stringify(result), isoNow(), jobId);
    return result;
  }

  recordWakeDecision(runId, signal) {
    const run = this.getRun(runId);
    if (!run) throw new Error("Ausführung wurde nicht gefunden.");
    const job = this.getJob(run.job_id);
    if (!job?.wake_enabled) return run;
    const decision = signal?.wake_agent === false ? "skip" : "wake";
    const context = signal?.context === null || signal?.context === undefined ? null : JSON.stringify(signal.context);
    this.db.prepare("UPDATE jobs SET wake_decision=?,wake_context_json=?,wake_decided_at=?,updated_at=? WHERE id=?")
      .run(decision, context, isoNow(), isoNow(), job.id);
    if (decision === "skip") {
      this.db.prepare("UPDATE runs SET wake_status='not_requested',wake_next_attempt_at=NULL,wake_error=NULL WHERE id=?")
        .run(runId);
    }
    return this.getRun(runId);
  }

  createJob(input) {
    const job = validateJobInput(input);
    const now = isoNow();
    const id = randomUUID();
    const nextRunAt = job.job_type === "one_time" ? (job.enabled ? job.scheduled_at : null) :
      job.job_type === "recurring" && job.enabled ? nextOccurrence(job.schedule, job.timezone, new Date()).toISOString() : null;
    this.db.prepare(`INSERT INTO jobs (
      id,name,description,schedule,timezone,command_type,command_path,arguments_json,working_directory,
      enabled,unattended,timeout_seconds,overlap_policy,misfire_policy,capture_output,next_run_at,created_at,updated_at,
      job_type,scheduled_at,auto_archive,archived,wake_enabled,wake_thread_id,wake_working_directory,wake_sandbox_mode,wake_approval_policy,
      command_sha256,safety_classification,required_credential_refs_json,required_endpoints_json,expected_artifacts_json,dependency_manifest_json,wake_condition,wake_decision
    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
      id, job.name, job.description, job.schedule, job.timezone, job.command_type, job.command_path,
      JSON.stringify(job.arguments), job.working_directory, Number(job.enabled), Number(job.unattended),
      job.timeout_seconds, job.overlap_policy, job.misfire_policy, Number(job.capture_output), nextRunAt, now, now,
      job.job_type, job.scheduled_at, Number(job.auto_archive), 0, Number(job.wake_enabled), job.wake_thread_id,
      job.wake_working_directory, job.wake_sandbox_mode, job.wake_approval_policy,
      job.command_sha256, job.safety_classification, JSON.stringify(job.required_credential_refs),
      JSON.stringify(job.required_endpoints), JSON.stringify(job.expected_artifacts), JSON.stringify(job.dependency_manifest), job.wake_condition,
      job.wake_condition === "always" ? "wake" : "pending",
    );
    return this.getJob(id);
  }

  updateJob(id, input) {
    const existing = this.getJob(id);
    if (!existing) throw new Error("Job wurde nicht gefunden.");
    const job = validateJobInput(input, existing);
    const nextRunAt = job.job_type === "one_time" ? (job.enabled ? job.scheduled_at : null) :
      job.job_type === "recurring" && job.enabled ? nextOccurrence(job.schedule, job.timezone, new Date()).toISOString() : null;
    this.db.prepare(`UPDATE jobs SET
      name=?,description=?,schedule=?,timezone=?,command_type=?,command_path=?,arguments_json=?,working_directory=?,
      enabled=?,unattended=?,timeout_seconds=?,overlap_policy=?,misfire_policy=?,capture_output=?,next_run_at=?,updated_at=?,
      job_type=?,scheduled_at=?,auto_archive=?,wake_enabled=?,wake_thread_id=?,wake_working_directory=?,wake_sandbox_mode=?,wake_approval_policy=?,
      command_sha256=?,safety_classification=?,required_credential_refs_json=?,required_endpoints_json=?,expected_artifacts_json=?,dependency_manifest_json=?,
      wake_condition=?,wake_decision=?,wake_context_json=NULL,wake_decided_at=NULL,
      preflight_status='pending',preflight_checked_at=NULL,preflight_json=NULL
      WHERE id=?`).run(
      job.name, job.description, job.schedule, job.timezone, job.command_type, job.command_path,
      JSON.stringify(job.arguments), job.working_directory, Number(job.enabled), Number(job.unattended),
      job.timeout_seconds, job.overlap_policy, job.misfire_policy, Number(job.capture_output), nextRunAt, isoNow(),
      job.job_type, job.scheduled_at, Number(job.auto_archive), Number(job.wake_enabled), job.wake_thread_id,
      job.wake_working_directory, job.wake_sandbox_mode, job.wake_approval_policy,
      job.command_sha256, job.safety_classification, JSON.stringify(job.required_credential_refs),
      JSON.stringify(job.required_endpoints), JSON.stringify(job.expected_artifacts), JSON.stringify(job.dependency_manifest), job.wake_condition,
      job.wake_condition === "always" ? "wake" : "pending", id,
    );
    return this.getJob(id);
  }

  deleteJob(id) {
    const result = this.db.prepare("DELETE FROM jobs WHERE id=?").run(id);
    if (result.changes !== 1) throw new Error("Job wurde nicht gefunden.");
    return { ok: true };
  }

  dueJobs(now = new Date()) {
    return this.db.prepare("SELECT * FROM jobs WHERE archived=0 AND enabled=1 AND unattended=1 AND next_run_at IS NOT NULL AND next_run_at<=? ORDER BY next_run_at")
      .all(now.toISOString()).map((row) => this.rowToJob(row));
  }

  advanceJob(job, after = new Date()) {
    if (job.job_type === "one_time") {
      this.db.prepare("UPDATE jobs SET enabled=0,next_run_at=NULL,updated_at=? WHERE id=?").run(isoNow(), job.id);
      return null;
    }
    const next = nextOccurrence(job.schedule, job.timezone, after).toISOString();
    this.db.prepare("UPDATE jobs SET next_run_at=?, updated_at=? WHERE id=?").run(next, isoNow(), job.id);
    return next;
  }

  createRun(jobId, triggerType, scheduledFor, status = "running") {
    const id = randomUUID();
    const startedAt = status === "running" ? isoNow() : null;
    const wakeEnabled = Boolean(this.getJob(jobId)?.wake_enabled);
    this.db.prepare(`INSERT INTO runs (
      id,job_id,trigger_type,scheduled_for,started_at,status,wake_status,wake_next_attempt_at
    ) VALUES (?,?,?,?,?,?,?,?)`).run(
      id, jobId, triggerType, scheduledFor || null, startedAt, status,
      wakeEnabled ? "pending" : "not_requested", wakeEnabled ? isoNow() : null,
    );
    if (startedAt) {
      this.db.prepare("UPDATE jobs SET last_run_at=?, last_status=? WHERE id=?").run(startedAt, status, jobId);
    }
    return this.getRun(id);
  }

  finishRun(id, status, exitCode, stdout, stderr, error) {
    const finishedAt = isoNow();
    const run = this.getRun(id);
    this.db.prepare("UPDATE runs SET finished_at=?,status=?,exit_code=?,stdout=?,stderr=?,error=? WHERE id=?")
      .run(finishedAt, status, exitCode, stdout || null, stderr || null, error || null, id);
    this.db.prepare("UPDATE jobs SET last_status=? WHERE id=?").run(status, run.job_id);
    this.pruneRecurringRunHistory();
    return this.getRun(id);
  }

  pruneRecurringRunHistory() {
    return this.db.prepare(`DELETE FROM runs
      WHERE finished_at IS NOT NULL AND datetime(finished_at) < datetime('now','-30 days')
      AND EXISTS (
        SELECT 1 FROM jobs
        WHERE jobs.id=runs.job_id AND jobs.job_type='recurring'
      )`).run().changes;
  }

  archiveAfterRun(jobId) {
    const job = this.getJob(jobId);
    if (job?.auto_archive) {
      this.db.prepare("UPDATE jobs SET archived=1,enabled=0,next_run_at=NULL,updated_at=? WHERE id=?").run(isoNow(), jobId);
    }
  }

  getRun(id) {
    return this.db.prepare("SELECT * FROM runs WHERE id=?").get(id) || null;
  }

  getRunDetails(id) {
    const run = this.getRun(id);
    if (!run) return null;
    return { run, job: this.getJob(run.job_id) };
  }

  listDueWakes(now = new Date(), maximumAttempts = 5) {
    return this.db.prepare(`SELECT runs.id FROM runs
      JOIN jobs ON jobs.id=runs.job_id
      WHERE runs.finished_at IS NOT NULL AND runs.wake_status IN ('pending','retrying')
      AND COALESCE(jobs.wake_decision,'pending') != 'skip'
      AND runs.wake_next_attempt_at IS NOT NULL AND runs.wake_next_attempt_at<=? AND runs.wake_attempts<?
      ORDER BY runs.wake_next_attempt_at, runs.rowid`).all(now.toISOString(), maximumAttempts);
  }

  claimWake(runId, maximumAttempts = 5) {
    const startedAt = isoNow();
    const result = this.db.prepare(`UPDATE runs SET wake_status='running',wake_attempts=wake_attempts+1,
      wake_started_at=?,wake_finished_at=NULL,wake_error=NULL
      WHERE id=? AND finished_at IS NOT NULL AND wake_status IN ('pending','retrying') AND wake_attempts<?
      AND EXISTS (SELECT 1 FROM jobs WHERE jobs.id=runs.job_id AND COALESCE(jobs.wake_decision,'pending') != 'skip')`)
      .run(startedAt, runId, maximumAttempts);
    if (result.changes !== 1) return null;
    const row = this.db.prepare(`SELECT
      r.id AS run_id,r.job_id,r.status AS run_status,r.exit_code,r.trigger_type,r.scheduled_for,
      r.started_at,r.finished_at,r.wake_attempts,j.name AS job_name,j.description AS job_description,
      j.wake_thread_id,j.wake_working_directory,j.wake_sandbox_mode,j.wake_approval_policy,
      j.wake_decision,j.wake_context_json
      FROM runs r JOIN jobs j ON j.id=r.job_id WHERE r.id=?`).get(runId);
    return row || null;
  }

  completeWake(runId) {
    this.db.prepare("UPDATE runs SET wake_status='succeeded',wake_finished_at=?,wake_next_attempt_at=NULL,wake_error=NULL WHERE id=?")
      .run(isoNow(), runId);
    return this.getRun(runId);
  }

  failWake(runId, error, retryAt = null) {
    const status = retryAt ? "retrying" : "failed";
    this.db.prepare("UPDATE runs SET wake_status=?,wake_finished_at=?,wake_next_attempt_at=?,wake_error=? WHERE id=?")
      .run(status, isoNow(), retryAt, redactOutput(error), runId);
    return this.getRun(runId);
  }

  listRuns(limit = 100, jobId = null, offset = 0) {
    const bounded = Math.min(Math.max(Number(limit) || 100, 1), 500);
    const boundedOffset = Math.max(Number(offset) || 0, 0);
    return jobId ?
      this.db.prepare("SELECT * FROM runs WHERE job_id=? ORDER BY COALESCE(started_at,scheduled_for) DESC, rowid DESC LIMIT ? OFFSET ?").all(jobId, bounded, boundedOffset) :
      this.db.prepare("SELECT * FROM runs ORDER BY COALESCE(started_at,scheduled_for) DESC, rowid DESC LIMIT ? OFFSET ?").all(bounded, boundedOffset);
  }

  countRuns(jobId = null) {
    const row = jobId ?
      this.db.prepare("SELECT COUNT(*) AS total FROM runs WHERE job_id=?").get(jobId) :
      this.db.prepare("SELECT COUNT(*) AS total FROM runs").get();
    return Number(row?.total || 0);
  }

  listRunPage(limit = 100, offset = 0, jobId = null) {
    const boundedLimit = Math.min(Math.max(Number(limit) || 100, 1), 100);
    const requestedOffset = Math.max(Number(offset) || 0, 0);
    const total = this.countRuns(jobId);
    const requestedPageOffset = Math.floor(requestedOffset / boundedLimit) * boundedLimit;
    const lastPageOffset = total > 0 ? Math.floor((total - 1) / boundedLimit) * boundedLimit : 0;
    const boundedOffset = Math.min(requestedPageOffset, lastPageOffset);
    const items = this.listRuns(boundedLimit, jobId, boundedOffset);
    return {
      items,
      total,
      limit: boundedLimit,
      offset: boundedOffset,
      has_previous: boundedOffset > 0,
      has_next: boundedOffset + items.length < total,
    };
  }
}

export class JobEngine {
  constructor(store, options = {}) {
    this.store = store;
    this.activeJobs = new Map();
    this.activeWakes = new Map();
    this.tickMs = options.tickMs || 10_000;
    this.maxConcurrent = options.maxConcurrent || 3;
    this.maxConcurrentWakes = options.maxConcurrentWakes || 1;
    this.maxWakeAttempts = options.maxWakeAttempts || 5;
    this.wakeRetrySeconds = options.wakeRetrySeconds || [10, 30, 120, 300, 900];
    this.wakeTimeoutMs = options.wakeTimeoutMs || 2 * 60 * 60 * 1000;
    this.wakeRunner = options.wakeRunner || null;
    this.misfireGraceMs = options.misfireGraceMs || 5 * MINUTE_MS;
    this.timer = null;
    this.ticking = false;
  }

  start() {
    if (this.timer) return;
    this.tick().catch((error) => console.error("Scheduler-Tick fehlgeschlagen:", error.message));
    this.timer = setInterval(() => {
      this.tick().catch((error) => console.error("Scheduler-Tick fehlgeschlagen:", error.message));
    }, this.tickMs);
    this.timer.unref?.();
  }

  async stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    const active = [...this.activeJobs.values()];
    for (const item of active) this.terminateProcess(item.child.pid);
    const wakes = [...this.activeWakes.values()];
    for (const item of wakes) item.controller.abort();
    await Promise.allSettled([
      ...active.map((item) => item.completion),
      ...wakes.map((item) => item.completion),
    ]);
  }

  async tick(now = new Date()) {
    if (this.ticking) return;
    this.ticking = true;
    try {
      for (const job of this.store.dueJobs(now)) {
        if (this.activeJobs.size >= this.maxConcurrent) break;
        const scheduledFor = job.next_run_at;
        this.store.advanceJob(job, now);
        const lateBy = now.getTime() - new Date(scheduledFor).getTime();
        if (job.misfire_policy === "skip" && lateBy > this.misfireGraceMs) {
          const triggerType = job.job_type === "one_time" ? "one_time" : "schedule";
          const run = this.store.createRun(job.id, triggerType, scheduledFor, "skipped");
          const finished = this.store.finishRun(run.id, "skipped", null, null, null, "Verpasster Termin gemäß Nachholregel übersprungen.");
          this.store.archiveAfterRun(job.id);
          this.queueWake(finished.id);
          continue;
        }
        this.launch(job, job.job_type === "one_time" ? "one_time" : "schedule", scheduledFor);
      }
      this.dispatchDueWakes(now);
    } finally {
      this.ticking = false;
    }
  }

  runNow(jobId) {
    const job = this.store.getJob(jobId);
    if (!job) throw new Error("Job wurde nicht gefunden.");
    return this.launch(job, "manual", null);
  }

  runActiveTest(jobId) {
    const job = this.store.getJob(jobId);
    if (!job || job.job_type !== "active_test") throw new Error("Aktivtest wurde nicht gefunden.");
    return this.launch(job, "active_test", null);
  }

  launch(job, triggerType, scheduledFor) {
    if (this.activeJobs.has(job.id)) {
      const run = this.store.createRun(job.id, triggerType, scheduledFor, "skipped");
      return this.store.finishRun(run.id, "skipped", null, null, null, "Eine Ausführung dieses Jobs läuft bereits.");
    }
    if (this.activeJobs.size >= this.maxConcurrent) throw new Error("Maximale Anzahl paralleler Jobs ist erreicht.");

    const preflight = this.store.runPreflight(job.id);
    if (!preflight.ok) {
      const failedRun = this.store.createRun(job.id, triggerType, scheduledFor, "running");
      const saved = this.store.finishRun(
        failedRun.id,
        "failed",
        null,
        null,
        null,
        "Job-Preflight fehlgeschlagen; Skript, Prüfsumme, Sicherheitsmanifest, Credential-Referenzen oder Endpunkte prüfen.",
      );
      this.store.recordWakeDecision(saved.id, { wake_agent: true, context: { preflight_failed: true } });
      this.store.archiveAfterRun(job.id);
      this.queueWake(saved.id);
      return saved;
    }
    job = this.store.getJob(job.id);

    const run = this.store.createRun(job.id, triggerType, scheduledFor, "running");
    const executable = job.command_type === "powershell" ? "pwsh.exe" : job.command_path;
    const args = job.command_type === "powershell" ? [
      "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned", "-File", job.command_path, ...job.arguments,
    ] : job.arguments;
    const child = spawn(executable, args, {
      cwd: job.working_directory,
      windowsHide: true,
      shell: false,
      env: { ...process.env, CODEX_JOB_ID: job.id, CODEX_JOB_RUN_ID: run.id, NO_COLOR: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    });

    const stdout = [];
    const stderr = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let timedOut = false;
    child.stdout.on("data", (chunk) => {
      const retainForWakeSignal = job.wake_enabled && job.wake_condition === "on_signal";
      if ((job.capture_output || retainForWakeSignal) && stdoutBytes < MAX_OUTPUT_BYTES) stdout.push(chunk.subarray(0, MAX_OUTPUT_BYTES - stdoutBytes));
      stdoutBytes += chunk.length;
    });
    child.stderr.on("data", (chunk) => {
      if (job.capture_output && stderrBytes < MAX_OUTPUT_BYTES) stderr.push(chunk.subarray(0, MAX_OUTPUT_BYTES - stderrBytes));
      stderrBytes += chunk.length;
    });

    const completion = new Promise((resolve) => {
      const timeout = setTimeout(() => {
        timedOut = true;
        this.terminateProcess(child.pid);
      }, job.timeout_seconds * 1000);
      timeout.unref?.();

      let finished = false;
      const finish = (status, code, error) => {
        if (finished) return;
        finished = true;
        clearTimeout(timeout);
        let finalStatus = status;
        let finalError = error;
        const rawStdout = Buffer.concat(stdout).toString("utf8");
        if (status === "succeeded") {
          const artifacts = verifyExpectedArtifacts(job, run.started_at);
          if (!artifacts.ok) {
            finalStatus = "failed";
            finalError = "Mindestens ein im Sicherheitsmanifest erwartetes Artefakt fehlt oder wurde für diese Ausführung nicht aktualisiert.";
          }
        }
        const saved = this.store.finishRun(
          run.id,
          finalStatus,
          Number.isInteger(code) ? code : null,
          job.capture_output ? redactOutput(rawStdout) : null,
          job.capture_output ? redactOutput(Buffer.concat(stderr).toString("utf8")) : null,
          finalError ? redactOutput(finalError) : null,
        );
        if (job.wake_enabled) {
          if (job.wake_condition === "on_signal" && finalStatus === "succeeded") {
            const signal = parseWakeSignal(rawStdout);
            this.store.recordWakeDecision(saved.id, signal.valid ? signal : {
              wake_agent: true,
              context: { wake_condition_error: signal.reason },
            });
          } else {
            this.store.recordWakeDecision(saved.id, {
              wake_agent: true,
              context: finalStatus === "succeeded" ? null : { run_status: finalStatus },
            });
          }
        }
        this.activeJobs.delete(job.id);
        this.store.archiveAfterRun(job.id);
        this.queueWake(saved.id);
        resolve(saved);
      };

      child.once("error", (error) => finish("failed", null, error.message));
      child.once("close", (code) => {
        if (timedOut) finish("timed_out", code, `Zeitlimit von ${job.timeout_seconds} Sekunden überschritten.`);
        else if (code === 0) finish("succeeded", code, null);
        else finish("failed", code, `Prozess wurde mit Code ${code} beendet.`);
      });
    });
    this.activeJobs.set(job.id, { child, runId: run.id, completion });
    return { ...run, pid: child.pid };
  }

  terminateProcess(pid) {
    if (!Number.isInteger(pid) || pid < 1) return;
    const killer = spawn("taskkill.exe", ["/PID", String(pid), "/T", "/F"], {
      windowsHide: true,
      stdio: "ignore",
    });
    killer.unref();
  }

  status() {
    return {
      running: true,
      active_jobs: this.activeJobs.size,
      max_concurrent: this.maxConcurrent,
      active_wakes: this.activeWakes.size,
      max_concurrent_wakes: this.maxConcurrentWakes,
    };
  }

  isJobActive(jobId) {
    return this.activeJobs.has(jobId);
  }

  queueWake(runId) {
    if (!this.wakeRunner) return;
    queueMicrotask(() => {
      try {
        this.launchWake(runId);
      } catch (error) {
        console.error("Codex-Reaktivierung konnte nicht eingeplant werden:", error.message);
      }
    });
  }

  dispatchDueWakes(now = new Date()) {
    if (!this.wakeRunner) return;
    for (const row of this.store.listDueWakes(now, this.maxWakeAttempts)) {
      if (this.activeWakes.size >= this.maxConcurrentWakes) break;
      this.launchWake(row.id);
    }
  }

  launchWake(runId) {
    if (!this.wakeRunner || this.activeWakes.has(runId) || this.activeWakes.size >= this.maxConcurrentWakes) return null;
    const context = this.store.claimWake(runId, this.maxWakeAttempts);
    if (!context) return null;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.wakeTimeoutMs);
    timeout.unref?.();
    const completion = Promise.resolve()
      .then(() => this.wakeRunner(context, { signal: controller.signal }))
      .then(() => this.store.completeWake(runId))
      .catch((error) => {
        const attempts = Number(context.wake_attempts || 1);
        const shouldRetry = attempts < this.maxWakeAttempts;
        const delaySeconds = this.wakeRetrySeconds[Math.min(attempts - 1, this.wakeRetrySeconds.length - 1)] || 900;
        const retryAt = shouldRetry ? new Date(Date.now() + delaySeconds * 1000).toISOString() : null;
        return this.store.failWake(runId, error?.message || String(error), retryAt);
      })
      .finally(() => {
        clearTimeout(timeout);
        this.activeWakes.delete(runId);
      });
    this.activeWakes.set(runId, { controller, completion });
    return { run_id: runId, wake_attempt: context.wake_attempts };
  }
}
