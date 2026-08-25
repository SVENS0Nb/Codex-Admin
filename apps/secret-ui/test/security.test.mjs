import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const storeScript = path.join(appRoot, "backend", "SecretUiStore.ps1");

function runStore(action, profile, options = {}) {
  const args = [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "RemoteSigned",
    "-File",
    storeScript,
    "-Action",
    action,
  ];
  if (options.id) args.push("-Id", options.id);
  return spawnSync("pwsh.exe", args, {
    encoding: "utf8",
    windowsHide: true,
    input: options.input ? JSON.stringify(options.input) : undefined,
    env: {
      ...process.env,
      LOCALAPPDATA: profile,
    },
  });
}

test("server is loopback-only and sends defensive headers", async () => {
  const source = await readFile(path.join(appRoot, "server.mjs"), "utf8");
  assert.match(source, /const host = "127\.0\.0\.1"/);
  assert.doesNotMatch(source, /const host = "0\.0\.0\.0"/);
  assert.match(source, /Content-Security-Policy/);
  assert.match(source, /X-Frame-Options/);
  assert.match(source, /SameSite=Strict/);
  assert.match(source, /HttpOnly/);
  assert.match(source, /x-csrf-token/);
  assert.match(source, /request\.headers\.origin/);
  assert.match(source, /HOMELAB_SECRET_UI_SERVICE/);
  assert.match(source, /service: "homelab-secret-ui"/);
  assert.match(source, /version: serviceVersion/);
  assert.match(source, /readFile\(path\.join\(appRoot, "package\.json"\)/);
});

test("client does not persist or render secrets as HTML", async () => {
  const source = await readFile(path.join(appRoot, "public", "app.js"), "utf8");
  for (const forbidden of [
    "localStorage",
    "sessionStorage",
    "innerHTML",
    "outerHTML",
    "insertAdjacentHTML",
  ]) {
    assert.equal(source.includes(forbidden), false, forbidden + " must not be used");
  }
  assert.match(source, /payload\.secret = null/);
  assert.match(source, /\/update/);
  assert.match(source, /beginEdit/);
  assert.match(source, /system-add/);
  assert.match(source, /navigableEndpoint/);
  assert.match(source, /noopener noreferrer/);
  assert.match(source, /internalEndpoint/);
  assert.match(source, /externalEndpoint/);
});

test("PowerShell backend passes its RFC 6238 self-test", () => {
  const result = spawnSync("pwsh.exe", [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "RemoteSigned",
    "-File",
    path.join(appRoot, "backend", "SecretUiStore.ps1"),
    "-Action",
    "SelfTest",
  ], {
    encoding: "utf8",
    windowsHide: true,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).ok, true);
});

test("empty secret store is serialized as a JSON array", async () => {
  const testProfile = await mkdtemp(path.join(tmpdir(), "homelab-secret-ui-"));
  try {
    const result = runStore("List", testProfile);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), []);
  } finally {
    await rm(testProfile, {
      recursive: true,
      force: true,
      maxRetries: 2,
    });
  }
});

test("records can be grouped and updated without exposing stored secrets", async () => {
  const testProfile = await mkdtemp(path.join(tmpdir(), "homelab-secret-ui-"));
  const firstSecret = "temporary-test-secret-one";
  try {
    const firstResult = runStore("Create", testProfile, {
      input: {
        system: "Testserver",
        internalEndpoint: "https://192.0.2.10:8006",
        externalEndpoint: "https://server.example.test",
        label: "Administrator",
        username: "admin",
        type: "password",
        secret: firstSecret,
        notes: "Original",
      },
    });
    assert.equal(firstResult.status, 0, firstResult.stderr);
    const first = JSON.parse(firstResult.stdout);
    assert.equal("secret" in first, false);

    const secondResult = runStore("Create", testProfile, {
      input: {
        system: "Testserver",
        internalEndpoint: "192.0.2.10",
        externalEndpoint: "",
        label: "Automation",
        username: "service",
        type: "api_key",
        secret: "temporary-test-api-key",
        notes: "",
      },
    });
    assert.equal(secondResult.status, 0, secondResult.stderr);
    const second = JSON.parse(secondResult.stdout);

    let listResult = runStore("List", testProfile);
    let records = JSON.parse(listResult.stdout);
    assert.equal(records.length, 2);
    assert.deepEqual(new Set(records.map((record) => record.system)), new Set(["Testserver"]));

    const updateResult = runStore("Update", testProfile, {
      id: first.id,
      input: {
        system: "Testserver",
        internalEndpoint: "https://service.example.invalid:8443",
        externalEndpoint: "https://server.example.test:8443",
        label: "Root-Zugang",
        username: "root",
        type: "password",
        secret: "",
        notes: "Bearbeitet",
      },
    });
    assert.equal(updateResult.status, 0, updateResult.stderr);
    const updated = JSON.parse(updateResult.stdout);
    assert.equal(updated.label, "Root-Zugang");
    assert.equal(updated.username, "root");
    assert.equal(updated.internalEndpoint, "https://service.example.invalid:8443");
    assert.equal(updated.externalEndpoint, "https://server.example.test:8443");
    assert.equal("secret" in updated, false);

    const endpointOnlyUpdate = runStore("UpdateEndpoints", testProfile, {
      id: first.id,
      input: {
        internalEndpoint: "https://service.example.invalid:8443",
      },
    });
    assert.equal(endpointOnlyUpdate.status, 0, endpointOnlyUpdate.stderr);
    const endpointOnly = JSON.parse(endpointOnlyUpdate.stdout);
    assert.equal(endpointOnly.internalEndpoint, "https://service.example.invalid:8443");
    assert.equal(endpointOnly.externalEndpoint, "https://server.example.test:8443");
    assert.equal(endpointOnly.label, "Root-Zugang");
    assert.equal(endpointOnly.username, "root");
    assert.equal(endpointOnly.notes, "Bearbeitet");
    assert.equal("secret" in endpointOnly, false);

    const cipherPath = path.join(
      testProfile,
      "CodexAdmin",
      "secret-ui",
      first.id + ".vault.secret",
    );
    const cipherText = await readFile(cipherPath, "utf8");
    assert.equal(cipherText.includes(firstSecret), false);
    assert.equal(cipherText.includes("Root-Zugang"), false);
    assert.equal(cipherText.includes("service.example.invalid"), false);
    assert.equal(cipherText.includes("server.example.test"), false);

    const invalidTypeChange = runStore("Update", testProfile, {
      id: first.id,
      input: {
        system: "Testserver",
        internalEndpoint: "https://service.example.invalid:8443",
        externalEndpoint: "https://server.example.test:8443",
        label: "Root-Zugang",
        username: "root",
        type: "totp",
        secret: "",
        notes: "Bearbeitet",
      },
    });
    assert.notEqual(invalidTypeChange.status, 0);

    const totpUpdate = runStore("Update", testProfile, {
      id: first.id,
      input: {
        system: "Testserver",
        internalEndpoint: "https://service.example.invalid:8443",
        externalEndpoint: "https://server.example.test:8443",
        label: "Root-TOTP",
        username: "root",
        type: "totp",
        secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
        notes: "Typwechsel",
      },
    });
    assert.equal(totpUpdate.status, 0, totpUpdate.stderr);
    assert.equal(JSON.parse(totpUpdate.stdout).type, "totp");

    for (const id of [first.id, second.id]) {
      const deleteResult = runStore("Delete", testProfile, { id });
      assert.equal(deleteResult.status, 0, deleteResult.stderr);
    }
    listResult = runStore("List", testProfile);
    records = JSON.parse(listResult.stdout);
    assert.deepEqual(records, []);
  } finally {
    await rm(testProfile, {
      recursive: true,
      force: true,
      maxRetries: 2,
    });
  }
});
