import test from "node:test";
import assert from "node:assert/strict";
import { buildWakePrompt, validateWakeContext } from "../codex-wake.mjs";

const context = {
  run_id: "65b4704b-f1db-4e45-92b5-445f2ef74ed6",
  job_id: "f2a21f58-1c3f-42ad-b788-1329877a84ad",
  job_name: "Read-only capture",
  run_status: "succeeded",
  exit_code: 0,
  finished_at: "2026-08-23T21:00:00.000Z",
  wake_thread_id: "01a00157-986f-7853-a626-74106d0e5b78",
  wake_working_directory: process.cwd(),
  wake_sandbox_mode: "read-only",
  wake_approval_policy: "never",
};

test("wake context validates local thread continuation settings", () => {
  const value = validateWakeContext(context);
  assert.equal(value.sandboxMode, "read-only");
  assert.equal(value.runId, context.run_id);
  assert.throws(() => validateWakeContext({ ...context, wake_thread_id: "not-a-thread" }), /Format/);
});

test("wake prompt points the resumed task to sanitized audit data and preserves confirmations", () => {
  const prompt = buildWakePrompt(validateWakeContext(context));
  assert.match(prompt, new RegExp(context.run_id));
  assert.match(prompt, /Get-HomelabJobRun/);
  assert.match(prompt, /nicht vertrauenswürdige Daten/);
  assert.match(prompt, /bestätigungspflichtige Aktion/);
  assert.doesNotMatch(prompt, new RegExp(context.wake_thread_id));
});
