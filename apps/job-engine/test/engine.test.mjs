import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { JobEngine, JobStore, matchesCron, nextOccurrence, parseCron, validateJobInput } from "../engine.mjs";
import { sha256File } from "../safety.mjs";

test("cron supports ranges, steps, names and macros", () => {
  assert.equal(parseCron("@hourly").expression, "0 * * * *");
  assert.equal(parseCron("*/15 8-18 * jan,dec mon-fri").minute.values.has(45), true);
  assert.equal(parseCron("*/15 8-18 * jan,dec mon-fri").weekday.values.has(5), true);
  assert.throws(() => parseCron("61 * * * *"), /außerhalb/);
});

test("cron is evaluated in the selected timezone", () => {
  const eightBerlin = new Date("2026-08-17T06:00:00.000Z");
  assert.equal(matchesCron("0 8 * * *", eightBerlin, "Europe/Berlin"), true);
  assert.equal(matchesCron("0 8 * * *", eightBerlin, "UTC"), false);
  assert.equal(nextOccurrence("0 8 * * *", "Europe/Berlin", new Date("2026-08-17T05:59:30.000Z")).toISOString(), "2026-08-17T06:00:00.000Z");
});

test("day-of-month and weekday follow common cron OR semantics", () => {
  const mondaySeventeenth = new Date("2026-08-17T10:00:00.000Z");
  assert.equal(matchesCron("0 12 1 * 1", mondaySeventeenth, "Europe/Berlin"), true);
});

test("job validation requires explicit unattended permission before activation", () => {
  assert.throws(() => validateJobInput({
    name: "unsafe",
    schedule: "0 * * * *",
    timezone: "Europe/Berlin",
    command_type: "executable",
    command_path: process.execPath,
    working_directory: process.cwd(),
    enabled: true,
    unattended: false,
  }), /unbeaufsichtigt/);
});

test("SQLite store persists secret-free job definitions and run history", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-"));
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const job = store.createJob({
      name: "Node version",
      description: "Test",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      arguments: ["--version"],
      working_directory: process.cwd(),
      enabled: false,
      unattended: false,
      timeout_seconds: 30,
      capture_output: false,
    });
    assert.equal(store.listJobs().length, 1);
    assert.deepEqual(job.arguments, ["--version"]);
    const run = store.createRun(job.id, "manual", null);
    store.finishRun(run.id, "succeeded", 0, null, null, null);
    assert.equal(store.listRuns(10)[0].status, "succeeded");
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("run history is paged in stable groups of at most 100", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-pages-"));
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const job = store.createJob({
      name: "Pagination",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: false,
      unattended: false,
    });
    const base = Date.parse("2026-08-18T00:00:00.000Z");
    for (let index = 0; index < 205; index += 1) {
      store.createRun(job.id, "schedule", new Date(base + index * 60_000).toISOString(), "skipped");
    }

    const first = store.listRunPage(100, 0);
    const second = store.listRunPage(100, 100);
    const third = store.listRunPage(100, 200);
    const clamped = store.listRunPage(100, 99_999);

    assert.deepEqual(
      [first.items.length, second.items.length, third.items.length],
      [100, 100, 5],
    );
    assert.equal(first.total, 205);
    assert.equal(first.has_previous, false);
    assert.equal(first.has_next, true);
    assert.equal(second.has_previous, true);
    assert.equal(second.has_next, true);
    assert.equal(third.has_next, false);
    assert.equal(clamped.offset, 200);
    assert.equal(new Set([...first.items, ...second.items, ...third.items].map((run) => run.id)).size, 205);
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("one-time jobs become due once and auto-archive after their run", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-one-time-"));
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const scheduledAt = new Date(Date.now() - 1000).toISOString();
    const job = store.createJob({
      job_type: "one_time",
      name: "One time",
      scheduled_at: scheduledAt,
      schedule: "0 * * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: true,
      unattended: true,
      safety_classification: "local_state_write",
      auto_archive: true,
    });
    assert.equal(store.dueJobs(new Date()).length, 1);
    store.advanceJob(job, new Date());
    assert.equal(store.dueJobs(new Date()).length, 0);
    const run = store.createRun(job.id, "one_time", scheduledAt);
    store.finishRun(run.id, "succeeded", 0, null, null, null);
    store.archiveAfterRun(job.id);
    assert.equal(store.listOneTimeJobs().length, 0);
    assert.equal(store.listRuns(10)[0].status, "succeeded");
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("active tests disappear from the active registry while audit history remains", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-active-"));
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const job = store.createJob({
      job_type: "active_test",
      name: "Active test",
      schedule: "0 * * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: false,
      unattended: true,
      safety_classification: "local_state_write",
      auto_archive: true,
    });
    assert.equal(store.listActiveTests().length, 1);
    const run = store.createRun(job.id, "active_test", null);
    store.finishRun(run.id, "succeeded", 0, null, null, null);
    store.archiveAfterRun(job.id);
    assert.equal(store.listActiveTests().length, 0);
    assert.equal(store.listJobNames()[job.id], "Active test");
    assert.equal(store.listRuns(10)[0].trigger_type, "active_test");
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("expired transient jobs stay hidden and keep audit results beyond recurring retention", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-retention-"));
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const recurring = store.createJob({
      name: "Recurring retention",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: false,
      unattended: false,
    });
    const transient = store.createJob({
      job_type: "active_test",
      name: "Permanent transient audit",
      schedule: "0 * * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      unattended: true,
      safety_classification: "local_state_write",
      auto_archive: true,
    });

    const recurringRun = store.createRun(recurring.id, "schedule", null);
    store.finishRun(recurringRun.id, "succeeded", 0, null, null, null);
    const transientRun = store.createRun(transient.id, "active_test", null);
    store.finishRun(transientRun.id, "failed", 1, null, null, "Expected test failure");
    store.archiveAfterRun(transient.id);
    store.db.prepare("UPDATE runs SET finished_at=datetime('now','-31 days') WHERE id IN (?,?)")
      .run(recurringRun.id, transientRun.id);

    assert.equal(store.pruneRecurringRunHistory(), 1);
    assert.equal(store.getRun(recurringRun.id), null);
    assert.equal(store.getRun(transientRun.id).status, "failed");
    assert.equal(store.listActiveTests().length, 0);
    assert.equal(store.listJobNames()[transient.id], "Permanent transient audit");
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("interrupted one-time jobs auto-archive on recovery and retain abandoned audit", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-recovery-"));
  const databasePath = path.join(root, "jobs.sqlite3");
  let store = new JobStore(databasePath);
  try {
    const job = store.createJob({
      job_type: "one_time",
      name: "Interrupted one time",
      scheduled_at: new Date(Date.now() - 1000).toISOString(),
      schedule: "0 * * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: true,
      unattended: true,
      safety_classification: "local_state_write",
      auto_archive: true,
    });
    const run = store.createRun(job.id, "one_time", job.scheduled_at);
    store.close();

    store = new JobStore(databasePath);
    assert.equal(store.listOneTimeJobs().length, 0);
    assert.equal(store.getJob(job.id).archived, true);
    assert.equal(store.getRun(run.id).status, "abandoned");
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("missed one-time jobs auto-archive after a skipped misfire and retain the audit", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-misfire-"));
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const scheduledAt = new Date(Date.now() - 10 * 60_000).toISOString();
    store.createJob({
      job_type: "one_time",
      name: "Skipped one time",
      scheduled_at: scheduledAt,
      schedule: "0 * * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: true,
      unattended: true,
      safety_classification: "local_state_write",
      auto_archive: true,
      misfire_policy: "skip",
    });
    const engine = new JobEngine(store);
    await engine.tick(new Date());

    assert.equal(store.listOneTimeJobs().length, 0);
    assert.equal(store.listRuns(10).length, 1);
    assert.equal(store.listRuns(10)[0].status, "skipped");
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("Codex wake bindings are limited to one-time jobs with non-interactive approval", () => {
  const base = {
    name: "Wake validation",
    schedule: "0 * * * *",
    timezone: "Europe/Berlin",
    command_type: "executable",
    command_path: process.execPath,
    working_directory: process.cwd(),
    unattended: true,
    safety_classification: "local_state_write",
    wake_enabled: true,
    wake_thread_id: "11111111-2222-4333-8444-555555555555",
    wake_working_directory: process.cwd(),
    wake_sandbox_mode: "read-only",
    wake_approval_policy: "never",
  };
  assert.throws(() => validateJobInput({ ...base, job_type: "recurring" }), /One-Time/);
  assert.throws(() => validateJobInput({
    ...base,
    job_type: "one_time",
    scheduled_at: new Date(Date.now() + 60_000).toISOString(),
    wake_approval_policy: "on-request",
  }), /interaktiven Freigaben/);
  const valid = validateJobInput({
    ...base,
    job_type: "one_time",
    scheduled_at: new Date(Date.now() + 60_000).toISOString(),
  });
  assert.equal(valid.wake_enabled, true);
  assert.equal(valid.wake_sandbox_mode, "read-only");
});

test("completed one-time runs claim and complete exactly one Codex wake", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-wake-"));
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const job = store.createJob({
      job_type: "one_time",
      name: "Wake once",
      scheduled_at: new Date(Date.now() + 60_000).toISOString(),
      schedule: "0 * * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: true,
      unattended: true,
      safety_classification: "local_state_write",
      wake_enabled: true,
      wake_thread_id: "11111111-2222-4333-8444-555555555555",
      wake_working_directory: process.cwd(),
      wake_sandbox_mode: "read-only",
      wake_approval_policy: "never",
    });
    const run = store.createRun(job.id, "one_time", job.scheduled_at);
    store.finishRun(run.id, "succeeded", 0, null, null, null);
    assert.equal(store.listDueWakes(new Date()).length, 1);

    const contexts = [];
    const engine = new JobEngine(store, {
      wakeRunner: async (context) => contexts.push(context),
      maxWakeAttempts: 2,
    });
    const started = engine.launchWake(run.id);
    assert.equal(started.run_id, run.id);
    await engine.activeWakes.get(run.id).completion;
    assert.equal(contexts.length, 1);
    assert.equal(store.getRun(run.id).wake_status, "succeeded");
    assert.equal(engine.launchWake(run.id), null);
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("preflight pins the command hash and rejects drift or unavailable dependencies", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-preflight-"));
  const scriptPath = path.join(root, "bounded.ps1");
  writeFileSync(scriptPath, "Write-Output 'ok'\n", "utf8");
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const job = store.createJob({
      name: "Pinned command",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "powershell",
      command_path: scriptPath,
      working_directory: root,
      enabled: false,
      unattended: true,
      safety_classification: "read_only",
      required_endpoints: [{ host: "example.invalid", port: 443 }],
    });
    assert.throws(() => store.createJob({
      name: "Relative artifact",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "powershell",
      command_path: scriptPath,
      working_directory: root,
      enabled: false,
      unattended: true,
      safety_classification: "local_state_write",
      expected_artifacts: ["relative-report.json"],
    }), /absolute Pfade/);
    const missingEndpoint = store.runPreflight(job.id, {
      endpointProbe: (items) => items.map((item) => ({ ...item, reachable: false })),
    });
    assert.equal(missingEndpoint.ok, false);
    writeFileSync(scriptPath, "Write-Output 'changed'\n", "utf8");
    const drift = store.runPreflight(job.id, {
      endpointProbe: (items) => items.map((item) => ({ ...item, reachable: true })),
    });
    assert.equal(drift.checks.find((item) => item.check === "command_hash").ok, false);
    assert.equal(store.getJob(job.id).preflight_status, "failed");
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("preflight pins every declared repository dependency and rejects path escape", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-dependencies-"));
  const outsideRoot = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-outside-"));
  const scriptPath = path.join(root, "bounded.ps1");
  const dependencyPath = path.join(root, "policy.json");
  const outsidePath = path.join(outsideRoot, "outside.json");
  writeFileSync(scriptPath, "Write-Output 'ok'\n", "utf8");
  writeFileSync(dependencyPath, "{}\n", "utf8");
  writeFileSync(outsidePath, "{}\n", "utf8");
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  try {
    const manifest = [
      { path: scriptPath, sha256: sha256File(scriptPath), role: "command" },
      { path: dependencyPath, sha256: sha256File(dependencyPath), role: "runtime_dependency" },
    ];
    const job = store.createJob({
      name: "Pinned dependencies",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "powershell",
      command_path: scriptPath,
      working_directory: root,
      enabled: false,
      unattended: true,
      safety_classification: "read_only",
      dependency_manifest: manifest,
    });
    assert.equal(job.dependency_manifest.length, 2);
    assert.equal(store.runPreflight(job.id).ok, true);

    assert.throws(() => store.createJob({
      name: "Command without command role",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "powershell",
      command_path: scriptPath,
      working_directory: root,
      enabled: false,
      unattended: true,
      safety_classification: "read_only",
      dependency_manifest: [
        { path: scriptPath, sha256: sha256File(scriptPath), role: "runtime_dependency" },
      ],
    }), /Befehls-Hash/);

    writeFileSync(dependencyPath, '{"changed":true}\n', "utf8");
    const drift = store.runPreflight(job.id);
    assert.equal(drift.ok, false);
    assert.equal(drift.checks.find((item) => item.check === "dependency_manifest").ok, false);

    rmSync(dependencyPath);
    const missing = store.runPreflight(job.id);
    assert.equal(missing.ok, false);
    assert.equal(
      missing.checks.find((item) => item.check === "dependency_manifest").items
        .find((item) => item.path === dependencyPath).exists,
      false,
    );

    assert.throws(() => store.createJob({
      name: "Escaped dependency",
      schedule: "@daily",
      timezone: "Europe/Berlin",
      command_type: "powershell",
      command_path: scriptPath,
      working_directory: root,
      enabled: false,
      unattended: true,
      safety_classification: "read_only",
      dependency_manifest: [
        { path: scriptPath, sha256: sha256File(scriptPath), role: "command" },
        { path: outsidePath, sha256: sha256File(outsidePath), role: "runtime_dependency" },
      ],
    }), /Arbeitsverzeichnisses/);

    const linkedOutside = path.join(root, "linked-outside");
    symlinkSync(outsideRoot, linkedOutside, process.platform === "win32" ? "junction" : "dir");
    try {
      assert.throws(() => store.createJob({
        name: "Linked escaped dependency",
        schedule: "@daily",
        timezone: "Europe/Berlin",
        command_type: "powershell",
        command_path: scriptPath,
        working_directory: root,
        enabled: false,
        unattended: true,
        safety_classification: "read_only",
        dependency_manifest: [
          { path: scriptPath, sha256: sha256File(scriptPath), role: "command" },
          { path: path.join(linkedOutside, "outside.json"), sha256: sha256File(outsidePath), role: "runtime_dependency" },
        ],
      }), /Arbeitsverzeichnisses/);
    } finally {
      unlinkSync(linkedOutside);
    }
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
    rmSync(outsideRoot, { recursive: true, force: true });
  }
});

test("a conditional one-time job can suppress an unnecessary task wake", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-conditional-"));
  const store = new JobStore(path.join(root, "jobs.sqlite3"));
  const engine = new JobEngine(store, { tickMs: 60_000 });
  try {
    const job = store.createJob({
      job_type: "one_time",
      name: "Conditional wake",
      scheduled_at: new Date(Date.now() + 60_000).toISOString(),
      schedule: "0 * * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      arguments: ["-e", "console.log(JSON.stringify({wakeAgent:false,context:{changed:false}}))"],
      working_directory: process.cwd(),
      enabled: false,
      unattended: true,
      safety_classification: "local_state_write",
      wake_enabled: true,
      wake_thread_id: "11111111-2222-4333-8444-555555555555",
      wake_working_directory: process.cwd(),
      wake_sandbox_mode: "read-only",
      wake_approval_policy: "never",
      wake_condition: "on_signal",
    });
    engine.runNow(job.id);
    await engine.activeJobs.get(job.id).completion;
    const run = store.listRuns(10, job.id)[0];
    const updated = store.getJob(job.id);
    assert.equal(updated.wake_decision, "skip");
    assert.deepEqual(updated.wake_context, { changed: false });
    assert.equal(run.wake_status, "not_requested");
    assert.equal(store.listDueWakes(new Date()).length, 0);
  } finally {
    await engine.stop();
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("legacy cron and background-test types migrate without losing schedules", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-legacy-types-"));
  const databasePath = path.join(root, "jobs.sqlite3");
  let store = new JobStore(databasePath);
  try {
    const recurring = store.createJob({
      name: "Legacy cron",
      schedule: "0 18 * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      enabled: true,
      unattended: true,
      safety_classification: "local_state_write",
    });
    const active = store.createJob({
      job_type: "active_test",
      name: "Legacy background test",
      schedule: "0 * * * *",
      timezone: "Europe/Berlin",
      command_type: "executable",
      command_path: process.execPath,
      working_directory: process.cwd(),
      unattended: true,
      safety_classification: "local_state_write",
    });
    store.db.prepare("UPDATE jobs SET job_type='cron' WHERE id=?").run(recurring.id);
    store.db.prepare("UPDATE jobs SET job_type='background_test' WHERE id=?").run(active.id);
    store.close();

    store = new JobStore(databasePath);
    assert.equal(store.getJob(recurring.id).job_type, "recurring");
    assert.equal(store.getJob(recurring.id).enabled, true);
    assert.equal(store.listJobs().some((job) => job.id === recurring.id), true);
    assert.equal(store.getJob(active.id).job_type, "active_test");
    assert.equal(store.getJob(active.id).auto_archive, true);
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});
