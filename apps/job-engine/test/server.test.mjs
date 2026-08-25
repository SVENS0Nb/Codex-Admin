import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function reservePort() {
  const socket = net.createServer();
  await new Promise((resolve, reject) => {
    socket.once("error", reject);
    socket.listen(0, "127.0.0.1", resolve);
  });
  const port = socket.address().port;
  await new Promise((resolve) => socket.close(resolve));
  return port;
}

async function waitForReady(child) {
  await new Promise((resolve, reject) => {
    let output = "";
    const timer = setTimeout(() => reject(new Error("Test server did not become ready.")), 10_000);
    child.stdout.on("data", (chunk) => {
      output += chunk.toString("utf8");
      if (output.includes("Homelab Job Engine:")) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`Test server exited early with code ${code}.`));
    });
  });
}

test("state API exposes transient jobs and run pagination metadata", {
  skip: process.platform === "win32" && Number.parseInt(process.versions.node, 10) >= 25 ?
    "Node 25 crashes when a node:test worker owns a DatabaseSync HTTP child; covered by live PowerShell verification on Windows." : false,
}, async () => {
  const dataRoot = mkdtempSync(path.join(os.tmpdir(), "homelab-job-engine-api-"));
  const port = await reservePort();
  const shutdownToken = "job-engine-server-test";
  const child = spawn(process.execPath, [path.join(appRoot, "server.mjs")], {
    cwd: appRoot,
    env: {
      ...process.env,
      HOMELAB_JOB_ENGINE_PORT: String(port),
      HOMELAB_JOB_ENGINE_DATA: dataRoot,
      HOMELAB_JOB_ENGINE_TEST_SHUTDOWN_TOKEN: shutdownToken,
    },
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });

  try {
    await waitForReady(child);
    const origin = `http://127.0.0.1:${port}`;
    const home = await fetch(`${origin}/`);
    const cookie = home.headers.get("set-cookie").split(";", 1)[0];
    const html = await home.text();
    const csrf = html.match(/meta name="csrf-token" content="([^"]+)"/)?.[1];
    assert.ok(csrf);
    const mutationHeaders = {
      Cookie: cookie,
      Origin: origin,
      "Content-Type": "application/json",
      "X-CSRF-Token": csrf,
    };
    const oneTime = await fetch(`${origin}/api/one-time-jobs`, {
      method: "POST",
      headers: mutationHeaders,
      body: JSON.stringify({
        name: "API one time",
        scheduled_at: new Date(Date.now() + 3_600_000).toISOString(),
        command_type: "executable",
        command_path: process.execPath,
        working_directory: process.cwd(),
        wake_enabled: true,
        wake_thread_id: "01a00157-986f-7853-a626-74106d0e5b78",
        wake_working_directory: process.cwd(),
        wake_sandbox_mode: "read-only",
        wake_approval_policy: "never",
        safety_classification: "local_state_write",
      }),
    });
    assert.equal(oneTime.status, 201);
    const oneTimeJob = await oneTime.json();
    const preflight = await fetch(`${origin}/api/jobs/${oneTimeJob.id}/preflight`, {
      method: "POST",
      headers: mutationHeaders,
      body: "{}",
    });
    assert.equal(preflight.status, 200);
    assert.equal((await preflight.json()).ok, true);

    const health = await fetch(`${origin}/healthz`);
    const healthPayload = await health.json();
    assert.equal(healthPayload.version, "1.8.0");

    const response = await fetch(`${origin}/api/state?runs_offset=0`, { headers: { Cookie: cookie } });
    assert.equal(response.status, 200);
    const state = await response.json();
    assert.equal(state.one_time_jobs.length, 1);
    assert.equal(state.one_time_jobs[0].wake_thread_bound, true);
    assert.equal("wake_thread_id" in state.one_time_jobs[0], false);
    assert.deepEqual(state.active_tests, []);
    assert.deepEqual(state.runs_page, {
      total: 0,
      limit: 100,
      offset: 0,
      has_previous: false,
      has_next: false,
    });
  } finally {
    if (child.exitCode === null) {
      try {
        await fetch(`http://127.0.0.1:${port}/__test__/shutdown`, {
          method: "POST",
          headers: { "X-Test-Shutdown-Token": shutdownToken },
        });
      } catch {
        child.kill();
      }
    }
    await new Promise((resolve) => child.once("exit", resolve));
    rmSync(dataRoot, { recursive: true, force: true });
  }
});
