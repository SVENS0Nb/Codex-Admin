import { backup, DatabaseSync } from "node:sqlite";
import { existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import net from "node:net";
import path from "node:path";

import {
  contextBootstrap,
  databaseStatistics,
  freshnessReport,
  integrityReport,
  knowledgeBackupRoot,
  openKnowledgeDatabase,
  recordAccessTest,
  recordChange,
  recordDecision,
  recordFact,
  recordIncident,
  recordObservation,
  repositoryRoot,
  searchIncidents,
  searchKnowledge,
  synchronizeKnowledgeBase,
  upsertMaintenance,
} from "./database.js";
import { readFileSync } from "node:fs";

function output(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

async function readJsonStdin(): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    const buffer = Buffer.from(chunk);
    size += buffer.length;
    if (size > 65_536) throw new Error("Input exceeds 65536 bytes");
    chunks.push(buffer);
  }
  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (!text) throw new Error("JSON input is required on stdin");
  const value = JSON.parse(text) as unknown;
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("JSON input must be an object");
  return value as Record<string, unknown>;
}

function checkTcp(host: string, port: number, timeoutMs: number): Promise<{ reachable: boolean; latency_ms: number; error?: string }> {
  return new Promise((resolve) => {
    const started = Date.now();
    const socket = net.createConnection({ host, port });
    let settled = false;
    const finish = (result: { reachable: boolean; latency_ms: number; error?: string }) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finish({ reachable: true, latency_ms: Date.now() - started }));
    socket.once("timeout", () => finish({ reachable: false, latency_ms: Date.now() - started, error: "timeout" }));
    socket.once("error", (error) => finish({ reachable: false, latency_ms: Date.now() - started, error: error.message }));
  });
}

async function recordEndpointChecks(): Promise<unknown> {
  const inventory = JSON.parse(readFileSync(path.join(repositoryRoot, "inventory", "services.json"), "utf8")) as {
    services: Record<string, { enabled: boolean; base_url: string; tcp_port?: number }>;
  };
  const db = openKnowledgeDatabase();
  try {
    synchronizeKnowledgeBase(db);
    const results = [];
    for (const [systemId, service] of Object.entries(inventory.services)) {
      if (!service.enabled || !service.base_url) continue;
      const uri = new URL(service.base_url);
      const port = service.tcp_port || Number(uri.port) || (uri.protocol === "https:" ? 443 : 80);
      let result = await checkTcp(uri.hostname, port, 5_000);
      // A newly introduced internal DNS name can need one Windows resolver
      // round trip before the following connection succeeds. Record a failure
      // only when one immediate bounded retry also fails.
      if (!result.reachable) result = await checkTcp(uri.hostname, port, 5_000);
      recordObservation(db, {
        system_id: systemId,
        kind: "management_tcp_reachability",
        status: result.reachable ? "ok" : "critical",
        summary: result.reachable
          ? `${uri.hostname}:${port} reachable in ${result.latency_ms} ms`
          : `${uri.hostname}:${port} unreachable`,
        details: result.error ?? null,
        source: "scheduled_local_tcp_check",
        confidence: 1,
        valid_for_hours: 24,
      });
      results.push({ system_id: systemId, host: uri.hostname, port, ...result });
    }
    return { ok: results.every((item) => item.reachable), results };
  } finally {
    db.close();
  }
}

async function createBackup(retentionCount: number): Promise<unknown> {
  mkdirSync(knowledgeBackupRoot, { recursive: true });
  const db = openKnowledgeDatabase();
  const stamp = new Date().toISOString().replaceAll(":", "-").replaceAll(".", "-");
  const destination = path.resolve(knowledgeBackupRoot, `homelab-ops-${stamp}.sqlite3`);
  if (path.dirname(destination) !== path.resolve(knowledgeBackupRoot)) {
    db.close();
    throw new Error("Backup destination escaped the approved backup directory");
  }
  try {
    synchronizeKnowledgeBase(db);
    await backup(db, destination);
  } finally {
    db.close();
  }
  const backups = readdirSync(knowledgeBackupRoot)
    .filter((name) => /^homelab-ops-.*\.sqlite3$/.test(name))
    .sort()
    .reverse();
  return {
    ok: true,
    destination,
    retention_target: retentionCount,
    prune_requires_confirmation: true,
    prune_candidates: backups.slice(retentionCount),
  };
}

function verifyDatabaseFile(databasePath: string): unknown {
  const resolved = path.resolve(databasePath);
  if (!path.isAbsolute(databasePath) || !existsSync(resolved) || !statSync(resolved).isFile()) {
    throw new Error("An absolute existing SQLite database path is required");
  }
  const db = new DatabaseSync(resolved, { readOnly: true });
  try {
    const integrityRows = db.prepare("PRAGMA integrity_check").all() as Array<Record<string, unknown>>;
    const foreignKeyRows = db.prepare("PRAGMA foreign_key_check").all();
    const integrityOk = integrityRows.length === 1 && integrityRows[0]?.integrity_check === "ok";
    return {
      ok: integrityOk && foreignKeyRows.length === 0,
      integrity_ok: integrityOk,
      foreign_key_violations: foreignKeyRows.length,
      user_version: Number((db.prepare("PRAGMA user_version").get() as Record<string, unknown>).user_version),
    };
  } finally {
    db.close();
  }
}

async function main(): Promise<void> {
  const command = process.argv[2] ?? "context";
  if (command === "check-endpoints") {
    output(await recordEndpointChecks());
    return;
  }
  if (command === "backup") {
    const retention = Number(process.argv[3] ?? "30");
    if (!Number.isInteger(retention) || retention < 1 || retention > 365) {
      throw new Error("Backup retention must be an integer from 1 to 365");
    }
    output(await createBackup(retention));
    return;
  }
  if (command === "integrity-file") {
    if (!process.argv[3]) throw new Error("A database path is required");
    output(verifyDatabaseFile(process.argv[3]));
    return;
  }

  const db = openKnowledgeDatabase();
  try {
    switch (command) {
      case "init":
      case "sync":
        output({ ok: true, ...synchronizeKnowledgeBase(db) });
        break;
      case "context":
        synchronizeKnowledgeBase(db);
        output(contextBootstrap(db, { detail: process.argv[3] === "full" ? "full" : "compact" }));
        break;
      case "freshness":
        synchronizeKnowledgeBase(db);
        output(freshnessReport(db));
        break;
      case "integrity":
        synchronizeKnowledgeBase(db);
        output(integrityReport(db));
        break;
      case "stats":
        output(databaseStatistics(db));
        break;
      case "search": {
        const query = process.argv[3] ?? "";
        const limit = Number(process.argv[4] ?? "10");
        output(searchKnowledge(db, query, limit));
        break;
      }
      case "incident-search": {
        const query = process.argv[3] ?? "";
        const limit = Number(process.argv[4] ?? "10");
        output(searchIncidents(db, query, limit));
        break;
      }
      case "record-fact":
        output(recordFact(db, await readJsonStdin() as Parameters<typeof recordFact>[1]));
        break;
      case "record-observation":
        output(recordObservation(db, await readJsonStdin() as Parameters<typeof recordObservation>[1]));
        break;
      case "record-change":
        output(recordChange(db, await readJsonStdin() as Parameters<typeof recordChange>[1]));
        break;
      case "record-incident":
        output(recordIncident(db, await readJsonStdin() as Parameters<typeof recordIncident>[1]));
        break;
      case "record-decision":
        output(recordDecision(db, await readJsonStdin() as Parameters<typeof recordDecision>[1]));
        break;
      case "record-access-test":
        output(recordAccessTest(db, await readJsonStdin() as Parameters<typeof recordAccessTest>[1]));
        break;
      case "upsert-maintenance":
        output(upsertMaintenance(db, await readJsonStdin() as Parameters<typeof upsertMaintenance>[1]));
        break;
      default:
        throw new Error(`Unknown command: ${command}`);
    }
  } finally {
    db.close();
  }
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${JSON.stringify({ ok: false, error: message })}\n`);
  process.exitCode = 1;
});
