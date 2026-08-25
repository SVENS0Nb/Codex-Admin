import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("audit table has a bounded scroll area and 100-run pagination controls", async () => {
  const [html, css, script, server] = await Promise.all([
    readFile(path.join(appRoot, "public", "index.html"), "utf8"),
    readFile(path.join(appRoot, "public", "app.css"), "utf8"),
    readFile(path.join(appRoot, "public", "app.js"), "utf8"),
    readFile(path.join(appRoot, "server.mjs"), "utf8"),
  ]);

  assert.match(html, /id="runs-pagination"/);
  assert.match(html, /id="runs-prev"/);
  assert.match(html, /id="runs-next"/);
  assert.match(css, /\.runs-table\s*\{[^}]*max-height:\s*560px;[^}]*overflow:\s*auto;/s);
  assert.match(script, /runs_page/);
  assert.match(server, /listRunPage\(100,/);
  assert.match(html, /id="active-tests"/);
  assert.match(html, /id="one-time-jobs"/);
  assert.match(script, /active_tests/);
  assert.match(server, /\/api\/active-tests/);
  assert.match(server, /\/api\/one-time-jobs/);
  assert.match(html, /<th>Task<\/th>/);
  assert.match(script, /wake_status/);
  assert.match(script, /Task-Wakeup/);
  assert.match(html, /id="safety-classification"/);
  assert.match(html, /id="required-endpoints"/);
  assert.match(html, /id="expected-artifacts"/);
  assert.match(script, /\/preflight/);
  assert.match(script, /safety_classification/);
});
