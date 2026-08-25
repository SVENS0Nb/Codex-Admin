import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { ingestEvents, normalizeEvent, openDatabase, queryEvents, status } from "../unifi-security-log.mjs";

function sample(overrides = {}) {
  return {
    record_type: "event",
    timestamp: "2026-08-24T09:35:48.956790+0200",
    event_type: "alert",
    flow_id: "572643498788155",
    src_ip: "198.51.100.1",
    src_port: 34865,
    dest_ip: "192.0.2.30",
    dest_port: 443,
    proto: "TCP",
    app_proto: "http",
    alert: {
      action: "blocked",
      category: "Detection of a Network Scan",
      severity: 3,
      signature_id: 2029054,
      signature: "ET SCAN Zmap User-Agent (Inbound)",
      source: "ET",
      gid: 1,
      rev: 2,
    },
    ubnt: {},
    ...overrides,
  };
}

test("normalization retains only the explicit forensic fields", () => {
  const event = normalizeEvent({
    ...sample(),
    http: { hostname: "must-not-be-kept", url: "/private" },
    payload: "must-not-be-kept",
  });
  assert.equal(event.signature_id, 2029054);
  assert.equal(event.src_ip, "198.51.100.1");
  assert.equal(Object.hasOwn(event, "http"), false);
  assert.equal(Object.hasOwn(event, "payload"), false);
});

test("database deduplicates rescanned threat events", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "unifi-security-test-"));
  const databasePath = path.join(root, "events.sqlite3");
  try {
    const db = openDatabase(databasePath);
    const first = ingestEvents(db, [sample()]);
    const second = ingestEvents(db, [sample()]);
    db.close();
    assert.deepEqual(first, { inserted: 1, duplicates: 0, invalid: 0 });
    assert.deepEqual(second, { inserted: 0, duplicates: 1, invalid: 0 });
    assert.equal(status(databasePath).total_events, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("queries support action and signature filters", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "unifi-security-test-"));
  const databasePath = path.join(root, "events.sqlite3");
  try {
    const db = openDatabase(databasePath);
    ingestEvents(db, [sample(), sample({ flow_id: "2", alert: { ...sample().alert, action: "allowed", signature_id: 9 } })]);
    db.close();
    assert.equal(queryEvents(databasePath, { hours: 10000, action: "blocked" }).length, 1);
    assert.equal(queryEvents(databasePath, { hours: 10000, signatureId: 9 }).length, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
