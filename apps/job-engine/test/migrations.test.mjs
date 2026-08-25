import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { JobStore } from "../engine.mjs";
import { LATEST_JOB_SCHEMA_VERSION, migrateJobEngineDatabase } from "../migrations.mjs";

test("new and repeated JobStore opens preserve the numbered schema history", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-migration-new-"));
  const databasePath = path.join(root, "jobs.sqlite3");
  let store = new JobStore(databasePath);
  try {
    assert.equal(store.db.prepare("PRAGMA user_version").get().user_version, LATEST_JOB_SCHEMA_VERSION);
    assert.equal(store.db.prepare("SELECT COUNT(*) AS count FROM schema_migrations").get().count, LATEST_JOB_SCHEMA_VERSION);
    store.close();
    store = new JobStore(databasePath);
    assert.equal(store.db.prepare("PRAGMA user_version").get().user_version, LATEST_JOB_SCHEMA_VERSION);
    assert.equal(store.db.prepare("SELECT COUNT(*) AS count FROM schema_migrations").get().count, LATEST_JOB_SCHEMA_VERSION);
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a supported user_version zero legacy database is adopted without data loss", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-migration-legacy-"));
  const databasePath = path.join(root, "jobs.sqlite3");
  const db = new DatabaseSync(databasePath);
  const initialSql = readFileSync(new URL("../migrations/001_initial.sql", import.meta.url), "utf8");
  db.exec(initialSql);
  const now = new Date().toISOString();
  db.prepare(`INSERT INTO jobs(
    id,name,description,schedule,timezone,command_type,command_path,arguments_json,working_directory,
    enabled,unattended,timeout_seconds,overlap_policy,misfire_policy,capture_output,created_at,updated_at
  ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
    "11111111-2222-4333-8444-555555555555", "Legacy fixture", "", "0 * * * *", "Europe/Berlin",
    "executable", process.execPath, "[]", process.cwd(), 0, 0, 30, "skip", "run_once", 0, now, now,
  );
  db.close();

  const store = new JobStore(databasePath);
  try {
    const job = store.getJob("11111111-2222-4333-8444-555555555555");
    assert.equal(job.name, "Legacy fixture");
    assert.equal(job.dependency_manifest.length, 1);
    assert.equal(store.db.prepare("PRAGMA user_version").get().user_version, LATEST_JOB_SCHEMA_VERSION);
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("a legacy database with contradictory partial migration history fails closed", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-migration-history-"));
  const databasePath = path.join(root, "jobs.sqlite3");
  const db = new DatabaseSync(databasePath);
  try {
    db.exec(readFileSync(new URL("../migrations/001_initial.sql", import.meta.url), "utf8"));
    db.exec(`CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY,name TEXT NOT NULL,applied_at TEXT NOT NULL)`);
    db.prepare("INSERT INTO schema_migrations(version,name,applied_at) VALUES(1,?,?)")
      .run("001_wrong.sql", new Date().toISOString());
    assert.equal(db.prepare("PRAGMA user_version").get().user_version, 0);
    assert.throws(() => migrateJobEngineDatabase(db), /widerspricht PRAGMA user_version 0/);
    assert.equal(db.prepare("PRAGMA table_info(jobs)").all().some((row) => row.name === "dependency_manifest_json"), false);
  } finally {
    db.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("future schemas are rejected and a failed migration rolls back only its own version", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-migration-failure-"));
  const futurePath = path.join(root, "future.sqlite3");
  const futureDb = new DatabaseSync(futurePath);
  futureDb.exec(`PRAGMA user_version=${LATEST_JOB_SCHEMA_VERSION + 1}`);
  assert.throws(() => migrateJobEngineDatabase(futureDb), /Nicht unterstützte/);
  futureDb.close();

  const migrationRoot = path.join(root, "migrations");
  mkdirSync(migrationRoot);
  writeFileSync(path.join(migrationRoot, "001_base.sql"), "CREATE TABLE fixture(id INTEGER PRIMARY KEY);\n", "utf8");
  writeFileSync(path.join(migrationRoot, "002_broken.sql"), "ALTER TABLE fixture ADD COLUMN value TEXT; THIS IS INVALID;\n", "utf8");
  const rollbackPath = path.join(root, "rollback.sqlite3");
  const rollbackDb = new DatabaseSync(rollbackPath);
  assert.throws(() => migrateJobEngineDatabase(rollbackDb, { migrationRoot }));
  assert.equal(rollbackDb.prepare("PRAGMA user_version").get().user_version, 1);
  assert.equal(rollbackDb.prepare("SELECT COUNT(*) AS count FROM schema_migrations").get().count, 1);
  assert.equal(rollbackDb.prepare("PRAGMA table_info(fixture)").all().some((row) => row.name === "value"), false);
  rollbackDb.close();
  rmSync(root, { recursive: true, force: true });
});
