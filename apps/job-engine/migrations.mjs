import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const defaultMigrationRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "migrations");

const LEGACY_JOB_COLUMNS = [
  ["job_type", "TEXT NOT NULL DEFAULT 'recurring'"],
  ["scheduled_at", "TEXT"],
  ["auto_archive", "INTEGER NOT NULL DEFAULT 0"],
  ["archived", "INTEGER NOT NULL DEFAULT 0"],
  ["command_sha256", "TEXT"],
  ["safety_classification", "TEXT NOT NULL DEFAULT 'manual_only'"],
  ["required_credential_refs_json", "TEXT NOT NULL DEFAULT '[]'"],
  ["required_endpoints_json", "TEXT NOT NULL DEFAULT '[]'"],
  ["expected_artifacts_json", "TEXT NOT NULL DEFAULT '[]'"],
  ["preflight_status", "TEXT NOT NULL DEFAULT 'pending'"],
  ["preflight_checked_at", "TEXT"],
  ["preflight_json", "TEXT"],
  ["wake_enabled", "INTEGER NOT NULL DEFAULT 0"],
  ["wake_thread_id", "TEXT"],
  ["wake_working_directory", "TEXT"],
  ["wake_sandbox_mode", "TEXT"],
  ["wake_approval_policy", "TEXT"],
  ["wake_condition", "TEXT NOT NULL DEFAULT 'always'"],
  ["wake_decision", "TEXT NOT NULL DEFAULT 'pending'"],
  ["wake_context_json", "TEXT"],
  ["wake_decided_at", "TEXT"],
  ["dependency_manifest_json", "TEXT NOT NULL DEFAULT '[]'"],
];

const LEGACY_RUN_COLUMNS = [
  ["wake_status", "TEXT NOT NULL DEFAULT 'not_requested'"],
  ["wake_attempts", "INTEGER NOT NULL DEFAULT 0"],
  ["wake_next_attempt_at", "TEXT"],
  ["wake_started_at", "TEXT"],
  ["wake_finished_at", "TEXT"],
  ["wake_error", "TEXT"],
];

const REQUIRED_LEGACY_JOB_COLUMNS = [
  "id", "name", "schedule", "timezone", "command_type", "command_path",
  "description", "arguments_json", "working_directory", "enabled", "unattended", "timeout_seconds",
  "overlap_policy", "misfire_policy", "capture_output", "next_run_at", "last_run_at", "last_status",
  "created_at", "updated_at",
];
const REQUIRED_LEGACY_RUN_COLUMNS = [
  "id", "job_id", "trigger_type", "scheduled_for", "started_at", "finished_at", "status",
  "exit_code", "stdout", "stderr", "error",
];

function tableExists(db, name) {
  return Boolean(db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name));
}

function columnsFor(db, table) {
  return new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((row) => row.name));
}

export function loadJobEngineMigrations(migrationRoot = defaultMigrationRoot) {
  const entries = readdirSync(migrationRoot)
    .filter((name) => /^\d{3}_[a-z0-9_]+\.sql$/.test(name))
    .sort()
    .map((name) => ({
      version: Number.parseInt(name.slice(0, 3), 10),
      name,
      sql: readFileSync(path.join(migrationRoot, name), "utf8"),
    }));
  if (entries.length === 0) throw new Error("Keine Job-Engine-Migrationen gefunden.");
  entries.forEach((entry, index) => {
    if (entry.version !== index + 1) throw new Error("Job-Engine-Migrationen müssen lückenlos nummeriert sein.");
  });
  return entries;
}

export const LATEST_JOB_SCHEMA_VERSION = loadJobEngineMigrations().at(-1).version;

function createMigrationTable(db) {
  db.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT NOT NULL
  )`);
}

function validateRecordedMigrations(db, migrations, userVersion) {
  if (!tableExists(db, "schema_migrations")) {
    throw new Error("Job-Engine-Schema hat keine Migrationstabelle.");
  }
  const rows = db.prepare("SELECT version,name FROM schema_migrations ORDER BY version").all();
  for (let version = 1; version <= userVersion; version += 1) {
    const row = rows.find((candidate) => Number(candidate.version) === version);
    const expected = migrations[version - 1];
    if (!row || row.name !== expected.name) {
      throw new Error(`Job-Engine-Migrationshistorie ist bei Version ${version} inkonsistent.`);
    }
  }
  if (rows.some((row) => Number(row.version) > userVersion)) {
    throw new Error("Job-Engine-Migrationshistorie liegt vor PRAGMA user_version.");
  }
}

function adoptLegacySchema(db, migrations) {
  const jobsExist = tableExists(db, "jobs");
  const runsExist = tableExists(db, "runs");
  if (!jobsExist || !runsExist) {
    throw new Error("Unvollständiges Legacy-Job-Engine-Schema wird nicht automatisch verändert.");
  }
  const jobColumns = columnsFor(db, "jobs");
  const runColumns = columnsFor(db, "runs");
  if (REQUIRED_LEGACY_JOB_COLUMNS.some((name) => !jobColumns.has(name)) ||
      REQUIRED_LEGACY_RUN_COLUMNS.some((name) => !runColumns.has(name))) {
    throw new Error("Legacy-Job-Engine-Schema stimmt nicht mit einer unterstützten Signatur überein.");
  }
  if (tableExists(db, "schema_migrations")) {
    const migrationColumns = columnsFor(db, "schema_migrations");
    if (["version", "name", "applied_at"].some((name) => !migrationColumns.has(name))) {
      throw new Error("Legacy-Job-Engine-Migrationshistorie hat eine ungültige Struktur.");
    }
    const existingHistory = db.prepare("SELECT version,name FROM schema_migrations ORDER BY version").all();
    if (existingHistory.length > 0) {
      throw new Error("Legacy-Job-Engine-Migrationshistorie widerspricht PRAGMA user_version 0.");
    }
  }

  db.exec("BEGIN IMMEDIATE");
  try {
    createMigrationTable(db);
    for (const [name, definition] of LEGACY_JOB_COLUMNS) {
      if (!jobColumns.has(name)) db.exec(`ALTER TABLE jobs ADD COLUMN ${name} ${definition}`);
    }
    for (const [name, definition] of LEGACY_RUN_COLUMNS) {
      if (!runColumns.has(name)) db.exec(`ALTER TABLE runs ADD COLUMN ${name} ${definition}`);
    }
    db.exec(`
      CREATE INDEX IF NOT EXISTS idx_jobs_due ON jobs(enabled, unattended, next_run_at);
      CREATE INDEX IF NOT EXISTS idx_runs_job_started ON runs(job_id, started_at DESC);
      CREATE INDEX IF NOT EXISTS idx_runs_wake_due ON runs(wake_status, wake_next_attempt_at);
      UPDATE jobs SET job_type='recurring' WHERE job_type='cron';
      UPDATE jobs SET job_type='active_test',auto_archive=1 WHERE job_type='background_test';
    `);
    const insert = db.prepare("INSERT OR REPLACE INTO schema_migrations(version,name,applied_at) VALUES(?,?,?)");
    const appliedAt = new Date().toISOString();
    for (const migration of migrations) insert.run(migration.version, migration.name, appliedAt);
    db.exec(`PRAGMA user_version=${migrations.at(-1).version}`);
    db.exec("COMMIT");
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch { /* transaction may already be closed */ }
    throw error;
  }
}

export function migrateJobEngineDatabase(db, { migrationRoot = defaultMigrationRoot } = {}) {
  const migrations = loadJobEngineMigrations(migrationRoot);
  const latest = migrations.at(-1).version;
  let userVersion = Number(db.prepare("PRAGMA user_version").get().user_version);
  if (!Number.isInteger(userVersion) || userVersion < 0 || userVersion > latest) {
    throw new Error(`Nicht unterstützte Job-Engine-Schema-Version ${userVersion}; erwartet höchstens ${latest}.`);
  }

  const hasJobs = tableExists(db, "jobs");
  const hasRuns = tableExists(db, "runs");
  if (userVersion === 0 && (hasJobs || hasRuns)) {
    adoptLegacySchema(db, migrations);
    return latest;
  }
  if (userVersion > 0) validateRecordedMigrations(db, migrations, userVersion);

  for (const migration of migrations.slice(userVersion)) {
    db.exec("BEGIN IMMEDIATE");
    try {
      createMigrationTable(db);
      db.exec(migration.sql);
      db.prepare("INSERT INTO schema_migrations(version,name,applied_at) VALUES(?,?,?)")
        .run(migration.version, migration.name, new Date().toISOString());
      db.exec(`PRAGMA user_version=${migration.version}`);
      db.exec("COMMIT");
      userVersion = migration.version;
    } catch (error) {
      try { db.exec("ROLLBACK"); } catch { /* transaction may already be closed */ }
      throw error;
    }
  }
  validateRecordedMigrations(db, migrations, latest);
  return latest;
}
