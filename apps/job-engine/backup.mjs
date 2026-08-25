import { backup, DatabaseSync } from "node:sqlite";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { LATEST_JOB_SCHEMA_VERSION } from "./migrations.mjs";

function defaultDataRoot() {
  return path.join(process.env.LOCALAPPDATA || os.homedir(), "CodexAdmin", "job-engine");
}

function timestamp() {
  return new Date().toISOString().replaceAll(":", "-").replaceAll(".", "-");
}

function approvedDestination(dataRoot, destination) {
  const backupRoot = path.resolve(dataRoot, "backups");
  const target = path.resolve(destination);
  if (!path.isAbsolute(destination) || path.dirname(target) !== backupRoot) {
    throw new Error("Backup destination must be an absolute file directly inside the approved Job Engine backup directory.");
  }
  if (!/^jobs-\d{4}-\d{2}-\d{2}T[0-9Z-]+\.sqlite3$/.test(path.basename(target))) {
    throw new Error("Backup destination does not use the approved Job Engine backup filename.");
  }
  return { backupRoot, target };
}

function tableExists(db, name) {
  return Boolean(db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name));
}

export function verifyJobEngineDatabase(databasePath) {
  const resolved = path.resolve(databasePath);
  if (!existsSync(resolved) || !statSync(resolved).isFile()) {
    throw new Error("Job Engine database file was not found.");
  }
  const db = new DatabaseSync(resolved, { readOnly: true });
  try {
    const integrityRows = db.prepare("PRAGMA integrity_check").all();
    const foreignKeyRows = db.prepare("PRAGMA foreign_key_check").all();
    const integrityOk = integrityRows.length === 1 && integrityRows[0].integrity_check === "ok";
    const requiredColumns = {
      jobs: ["id", "name", "command_path", "command_sha256", "safety_classification", "dependency_manifest_json"],
      runs: ["id", "job_id", "status", "wake_status"],
      schema_migrations: ["version", "name", "applied_at"],
    };
    const schemaChecks = {};
    const counts = {};
    for (const table of ["jobs", "runs", "schema_migrations"]) {
      const exists = tableExists(db, table);
      const columns = exists
        ? new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((row) => row.name))
        : new Set();
      schemaChecks[table] = exists && requiredColumns[table].every((column) => columns.has(column));
      counts[table] = exists ? Number(db.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get().count) : null;
    }
    const userVersion = Number(db.prepare("PRAGMA user_version").get().user_version);
    const schemaOk = Object.values(schemaChecks).every(Boolean) && userVersion === LATEST_JOB_SCHEMA_VERSION;
    return {
      ok: integrityOk && foreignKeyRows.length === 0 && schemaOk,
      integrity_ok: integrityOk,
      foreign_key_violations: foreignKeyRows.length,
      schema_ok: schemaOk,
      schema_checks: schemaChecks,
      user_version: userVersion,
      expected_user_version: LATEST_JOB_SCHEMA_VERSION,
      counts,
    };
  } finally {
    db.close();
  }
}

export async function createJobEngineBackup({
  dataRoot = defaultDataRoot(),
  destination = null,
  retentionTarget = 30,
} = {}) {
  const resolvedDataRoot = path.resolve(dataRoot);
  const source = path.join(resolvedDataRoot, "jobs.sqlite3");
  if (!existsSync(source) || !statSync(source).isFile()) {
    throw new Error("Live Job Engine database was not found.");
  }
  if (!Number.isInteger(retentionTarget) || retentionTarget < 1 || retentionTarget > 365) {
    throw new Error("Retention target must be an integer from 1 to 365.");
  }
  const selectedDestination = destination || path.join(resolvedDataRoot, "backups", `jobs-${timestamp()}.sqlite3`);
  const { backupRoot, target } = approvedDestination(resolvedDataRoot, selectedDestination);
  mkdirSync(backupRoot, { recursive: true });
  const sourceDb = new DatabaseSync(source, { readOnly: true });
  try {
    await backup(sourceDb, target);
  } finally {
    sourceDb.close();
  }
  const verification = verifyJobEngineDatabase(target);
  if (!verification.ok) throw new Error("Created Job Engine backup failed SQLite verification.");
  const backups = readdirSync(backupRoot)
    .filter((name) => /^jobs-.*\.sqlite3$/.test(name))
    .sort()
    .reverse();
  return {
    ok: true,
    destination: target,
    bytes: statSync(target).size,
    verification,
    retention_target: retentionTarget,
    prune_requires_confirmation: true,
    prune_candidates: backups.slice(retentionTarget),
  };
}

export function restoreTest(backupPath) {
  const source = path.resolve(backupPath);
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-restore-"));
  const restored = path.join(temporaryRoot, "jobs-restored.sqlite3");
  try {
    copyFileSync(source, restored);
    const verification = verifyJobEngineDatabase(restored);
    if (!verification.ok) throw new Error("Restored Job Engine database failed verification.");
    return { ok: true, verification };
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

async function main() {
  const command = process.argv[2] || "backup";
  if (command === "backup") {
    const dataRoot = process.argv[3] || defaultDataRoot();
    process.stdout.write(`${JSON.stringify(await createJobEngineBackup({ dataRoot }), null, 2)}\n`);
    return;
  }
  if (command === "verify") {
    if (!process.argv[3]) throw new Error("A backup path is required.");
    process.stdout.write(`${JSON.stringify(verifyJobEngineDatabase(process.argv[3]), null, 2)}\n`);
    return;
  }
  if (command === "restore-test") {
    if (!process.argv[3]) throw new Error("A backup path is required.");
    process.stdout.write(`${JSON.stringify(restoreTest(process.argv[3]), null, 2)}\n`);
    return;
  }
  throw new Error("Unknown backup command.");
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  main().catch((error) => {
    process.stderr.write(`${JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) })}\n`);
    process.exitCode = 1;
  });
}
