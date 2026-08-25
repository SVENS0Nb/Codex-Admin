import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

import { createJobEngineBackup, restoreTest, verifyJobEngineDatabase } from "../backup.mjs";
import { JobStore } from "../engine.mjs";

test("online Job Engine backup includes WAL-visible state and restores cleanly", async () => {
  const dataRoot = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-backup-"));
  const store = new JobStore(path.join(dataRoot, "jobs.sqlite3"));
  try {
    const job = store.createJob({
      name: "Backup fixture",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: false,
      unattended: false,
    });
    const run = store.createRun(job.id, "manual", null);
    store.finishRun(run.id, "succeeded", 0, null, null, null);

    const result = await createJobEngineBackup({ dataRoot, retentionTarget: 1 });
    assert.equal(result.ok, true);
    assert.equal(result.verification.counts.jobs, 1);
    assert.equal(result.verification.counts.runs, 1);
    assert.equal(result.prune_requires_confirmation, true);
    assert.equal(existsSync(result.destination), true);
    assert.equal(verifyJobEngineDatabase(result.destination).ok, true);
    assert.equal(restoreTest(result.destination).ok, true);
  } finally {
    store.close();
    rmSync(dataRoot, { recursive: true, force: true });
  }
});

test("backup destination traversal and unapproved filenames are rejected", async () => {
  const dataRoot = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-backup-path-"));
  const store = new JobStore(path.join(dataRoot, "jobs.sqlite3"));
  try {
    await assert.rejects(
      createJobEngineBackup({ dataRoot, destination: path.join(dataRoot, "..", "escaped.sqlite3") }),
      /approved Job Engine backup directory/,
    );
    await assert.rejects(
      createJobEngineBackup({ dataRoot, destination: path.join(dataRoot, "backups", "arbitrary.sqlite3") }),
      /approved Job Engine backup filename/,
    );
  } finally {
    store.close();
    rmSync(dataRoot, { recursive: true, force: true });
  }
});

test("verification rejects an unrelated but internally valid SQLite file", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-wrong-schema-"));
  const databasePath = path.join(root, "unrelated.sqlite3");
  const db = new DatabaseSync(databasePath);
  try {
    db.exec("CREATE TABLE unrelated(id INTEGER PRIMARY KEY)");
  } finally {
    db.close();
  }
  try {
    const result = verifyJobEngineDatabase(databasePath);
    assert.equal(result.integrity_ok, true);
    assert.equal(result.schema_ok, false);
    assert.equal(result.ok, false);
    assert.throws(() => restoreTest(databasePath), /failed verification/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
