import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { isIP } from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";

const appRoot = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(appRoot, "..", "..");
const defaultDatabasePath = path.join(
  process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"),
  "CodexAdmin",
  "homelab",
  "unifi-security",
  "unifi-security.sqlite3",
);

function text(value, maximum = 500) {
  if (value === null || value === undefined) return null;
  return String(value)
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\b(Bearer|Basic|PVEAPIToken)\s+[A-Za-z0-9._~+/=-]+/gi, "$1 [REDACTED]")
    .replace(/\b(password|passwd|token|api[_-]?key|secret|authorization|cookie)\b\s*[:=]\s*([^\s,;]+)/gi, "$1=[REDACTED]")
    .trim()
    .slice(0, maximum);
}

function integer(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function ipAddress(value) {
  const candidate = text(value, 64);
  return candidate && isIP(candidate) ? candidate : null;
}

function timestamp(value) {
  const candidate = text(value, 80);
  const parsed = candidate ? new Date(candidate) : null;
  return parsed && !Number.isNaN(parsed.getTime()) ? parsed.toISOString() : null;
}

function canonicalEvent(event) {
  return JSON.stringify([
    event.occurred_at,
    event.flow_id,
    event.action,
    event.signature_id,
    event.src_ip,
    event.src_port,
    event.dest_ip,
    event.dest_port,
    event.protocol,
    event.app_protocol,
  ]);
}

export function normalizeEvent(source) {
  if (!source || source.record_type !== "event") return null;
  const occurredAt = timestamp(source.timestamp);
  if (!occurredAt) return null;
  const alert = source.alert && typeof source.alert === "object" ? source.alert : {};
  const ubnt = source.ubnt && typeof source.ubnt === "object" ? source.ubnt : {};
  const event = {
    occurred_at: occurredAt,
    event_type: text(source.event_type, 80),
    flow_id: text(source.flow_id, 80),
    action: text(alert.action, 40),
    category: text(alert.category, 300),
    severity: integer(alert.severity),
    signature_id: integer(alert.signature_id),
    signature: text(alert.signature, 500),
    signature_source: text(alert.source, 120),
    gid: integer(alert.gid),
    revision: integer(alert.rev),
    src_ip: ipAddress(source.src_ip),
    src_port: integer(source.src_port),
    dest_ip: ipAddress(source.dest_ip),
    dest_port: integer(source.dest_port),
    protocol: text(source.proto, 40),
    app_protocol: text(source.app_proto, 80),
    input_interface: text(source.in_iface, 120),
    output_interface: text(source.out_iface, 120),
    unifi_category: text(ubnt.ubnt_category, 200),
    classification: text(ubnt.classtype, 200),
    signature_type: text(ubnt.signature_type, 120),
    suricata_version: text(ubnt.suricata_version, 80),
  };
  event.event_key = createHash("sha256").update(canonicalEvent(event)).digest("hex");
  return event;
}

export function openDatabase(databasePath = defaultDatabasePath) {
  mkdirSync(path.dirname(databasePath), { recursive: true });
  const db = new DatabaseSync(databasePath);
  db.exec(`
    PRAGMA journal_mode=WAL;
    PRAGMA foreign_keys=ON;
    PRAGMA busy_timeout=5000;

    CREATE TABLE IF NOT EXISTS metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS collection_runs (
      id TEXT PRIMARY KEY,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      status TEXT NOT NULL CHECK(status IN ('running','succeeded','failed')),
      source_rows INTEGER NOT NULL DEFAULT 0,
      inserted_rows INTEGER NOT NULL DEFAULT 0,
      duplicate_rows INTEGER NOT NULL DEFAULT 0,
      invalid_rows INTEGER NOT NULL DEFAULT 0,
      error TEXT
    );

    CREATE TABLE IF NOT EXISTS security_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      event_key TEXT NOT NULL UNIQUE,
      occurred_at TEXT NOT NULL,
      collected_at TEXT NOT NULL,
      event_type TEXT,
      flow_id TEXT,
      action TEXT,
      category TEXT,
      severity INTEGER,
      signature_id INTEGER,
      signature TEXT,
      signature_source TEXT,
      gid INTEGER,
      revision INTEGER,
      src_ip TEXT,
      src_port INTEGER,
      dest_ip TEXT,
      dest_port INTEGER,
      protocol TEXT,
      app_protocol TEXT,
      input_interface TEXT,
      output_interface TEXT,
      unifi_category TEXT,
      classification TEXT,
      signature_type TEXT,
      suricata_version TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_security_events_occurred
      ON security_events(occurred_at DESC);
    CREATE INDEX IF NOT EXISTS idx_security_events_signature
      ON security_events(signature_id, occurred_at DESC);
    CREATE INDEX IF NOT EXISTS idx_security_events_source
      ON security_events(src_ip, occurred_at DESC);
    CREATE INDEX IF NOT EXISTS idx_collection_runs_started
      ON collection_runs(started_at DESC);

    CREATE VIEW IF NOT EXISTS blocked_security_events AS
      SELECT * FROM security_events WHERE lower(coalesce(action,''))='blocked';
  `);
  setMetadata(db, "schema_version", "1");
  setMetadata(db, "contains_raw_payload", "false");
  setMetadata(db, "source", "UniFi /var/log/ulog/threat.log via strict SSH pull");
  return db;
}

function setMetadata(db, key, value) {
  db.prepare(`
    INSERT INTO metadata(key,value,updated_at) VALUES(?,?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at
  `).run(key, String(value), new Date().toISOString());
}

function getMetadata(db, key, fallback = null) {
  return db.prepare("SELECT value FROM metadata WHERE key=?").get(key)?.value ?? fallback;
}

function remoteCollector(previousInode, previousOffset) {
  return `python3 - <<'PY'
import glob
import json
import os

current = '/var/log/ulog/threat.log'
previous_inode = ${Math.max(0, Number(previousInode) || 0)}
previous_offset = ${Math.max(0, Number(previousOffset) || 0)}

def compact(value, maximum):
    if value is None:
        return None
    value = ''.join(' ' if ord(ch) < 32 or ord(ch) == 127 else ch for ch in str(value))
    return value.strip()[:maximum]

def safe_event(obj):
    alert = obj.get('alert') if isinstance(obj.get('alert'), dict) else {}
    ubnt = obj.get('ubnt') if isinstance(obj.get('ubnt'), dict) else {}
    return {
        'record_type': 'event',
        'timestamp': compact(obj.get('timestamp'), 80),
        'event_type': compact(obj.get('event_type'), 80),
        'flow_id': compact(obj.get('flow_id'), 80),
        'src_ip': compact(obj.get('src_ip'), 64),
        'src_port': obj.get('src_port'),
        'dest_ip': compact(obj.get('dest_ip'), 64),
        'dest_port': obj.get('dest_port'),
        'proto': compact(obj.get('proto'), 40),
        'app_proto': compact(obj.get('app_proto'), 80),
        'in_iface': compact(obj.get('in_iface'), 120),
        'out_iface': compact(obj.get('out_iface'), 120),
        'alert': {
            'action': compact(alert.get('action'), 40),
            'category': compact(alert.get('category'), 300),
            'severity': alert.get('severity'),
            'signature_id': alert.get('signature_id'),
            'signature': compact(alert.get('signature'), 500),
            'source': compact(alert.get('source'), 120),
            'gid': alert.get('gid'),
            'rev': alert.get('rev'),
        },
        'ubnt': {
            'ubnt_category': compact(ubnt.get('ubnt_category'), 200),
            'classtype': compact(ubnt.get('classtype'), 200),
            'signature_type': compact(ubnt.get('signature_type'), 120),
            'suricata_version': compact(ubnt.get('suricata_version'), 80),
        },
    }

if not os.path.isfile(current):
    raise SystemExit('UniFi threat log is unavailable')

current_stat = os.stat(current)
sources = []
if previous_inode and previous_inode == current_stat.st_ino and previous_offset <= current_stat.st_size:
    sources.append((current, previous_offset))
elif previous_inode:
    prior_path = None
    for candidate in glob.glob('/var/log/ulog/threat.log*'):
        try:
            if os.path.isfile(candidate) and os.stat(candidate).st_ino == previous_inode:
                prior_path = candidate
                break
        except OSError:
            pass
    if prior_path:
        sources.append((prior_path, previous_offset))
    sources.append((current, 0))
else:
    sources.append((current, 0))

parsed = 0
invalid = 0
current_offset = 0
for source_path, start_offset in sources:
    with open(source_path, 'rb') as handle:
        handle.seek(min(start_offset, os.fstat(handle.fileno()).st_size))
        last_complete = handle.tell()
        while True:
            raw = handle.readline()
            if not raw:
                break
            if not raw.endswith(b'\\n'):
                break
            last_complete = handle.tell()
            line = raw.decode('utf-8', 'replace')
            position = line.find('{')
            if position < 0:
                invalid += 1
                continue
            try:
                obj = json.loads(line[position:])
            except Exception:
                invalid += 1
                continue
            print(json.dumps(safe_event(obj), separators=(',', ':'), sort_keys=True))
            parsed += 1
        if source_path == current:
            current_offset = last_complete

print(json.dumps({
    'record_type': 'cursor',
    'inode': current_stat.st_ino,
    'offset': current_offset,
    'size': current_stat.st_size,
    'parsed': parsed,
    'invalid': invalid,
    'source_count': len(sources),
}, separators=(',', ':'), sort_keys=True))
PY`;
}

function readInventory() {
  const inventory = JSON.parse(readFileSync(path.join(repoRoot, "inventory", "services.json"), "utf8"));
  const service = inventory?.services?.unifi;
  if (!service?.ssh_url || !service?.ssh_user) throw new Error("UniFi SSH inventory is incomplete.");
  const sshUrl = new URL(service.ssh_url);
  return {
    host: sshUrl.hostname,
    port: Number(sshUrl.port || 22),
    user: service.ssh_user,
  };
}

function executeRemoteCollection(previousInode, previousOffset) {
  const target = readInventory();
  const python = "python.exe";
  const helper = path.join(repoRoot, "scripts", "Invoke-SshCommand.py");
  const identity = path.join(os.homedir(), ".ssh", "codex_admin_ed25519");
  const knownHosts = path.join(os.homedir(), ".ssh", "known_hosts");
  for (const required of [helper, identity, knownHosts]) {
    if (!existsSync(required)) throw new Error(`Required local SSH component is missing: ${path.basename(required)}`);
  }
  const result = spawnSync(python, [
    helper,
    "--host", target.host,
    "--port", String(target.port),
    "--user", target.user,
    "--identity", identity,
    "--known-hosts", knownHosts,
    "--command", remoteCollector(previousInode, previousOffset),
  ], {
    encoding: "utf8",
    timeout: 60_000,
    maxBuffer: 32 * 1024 * 1024,
    windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`UniFi SSH collection failed with exit code ${result.status}: ${text(result.stderr, 300) || "no details"}`);
  }
  return String(result.stdout || "");
}

export function ingestEvents(db, events, collectedAt = new Date().toISOString()) {
  const statement = db.prepare(`
    INSERT OR IGNORE INTO security_events(
      event_key,occurred_at,collected_at,event_type,flow_id,action,category,severity,
      signature_id,signature,signature_source,gid,revision,src_ip,src_port,dest_ip,dest_port,
      protocol,app_protocol,input_interface,output_interface,unifi_category,classification,
      signature_type,suricata_version
    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
  `);
  let inserted = 0;
  let invalid = 0;
  db.exec("BEGIN IMMEDIATE");
  try {
    for (const source of events) {
      const event = normalizeEvent(source);
      if (!event) {
        invalid += 1;
        continue;
      }
      const result = statement.run(
        event.event_key, event.occurred_at, collectedAt, event.event_type, event.flow_id,
        event.action, event.category, event.severity, event.signature_id, event.signature,
        event.signature_source, event.gid, event.revision, event.src_ip, event.src_port,
        event.dest_ip, event.dest_port, event.protocol, event.app_protocol,
        event.input_interface, event.output_interface, event.unifi_category,
        event.classification, event.signature_type, event.suricata_version,
      );
      inserted += Number(result.changes || 0);
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return { inserted, duplicates: events.length - inserted - invalid, invalid };
}

export function sync(databasePath = defaultDatabasePath, remoteOutput = null) {
  const db = openDatabase(databasePath);
  const runId = randomUUID();
  const startedAt = new Date().toISOString();
  db.prepare("INSERT INTO collection_runs(id,started_at,status) VALUES(?,?,'running')").run(runId, startedAt);
  try {
    const previousInode = getMetadata(db, "source_inode", "0");
    const previousOffset = getMetadata(db, "source_offset", "0");
    const output = remoteOutput ?? executeRemoteCollection(previousInode, previousOffset);
    const events = [];
    let cursor = null;
    let transportInvalid = 0;
    for (const line of output.split(/\r?\n/)) {
      if (!line.trim()) continue;
      try {
        const record = JSON.parse(line);
        if (record.record_type === "event") events.push(record);
        else if (record.record_type === "cursor") cursor = record;
        else transportInvalid += 1;
      } catch {
        transportInvalid += 1;
      }
    }
    if (!cursor || !Number.isSafeInteger(Number(cursor.inode)) || !Number.isSafeInteger(Number(cursor.offset))) {
      throw new Error("UniFi collection returned no valid cursor.");
    }
    const result = ingestEvents(db, events, new Date().toISOString());
    db.exec("BEGIN IMMEDIATE");
    try {
      setMetadata(db, "source_inode", String(cursor.inode));
      setMetadata(db, "source_offset", String(cursor.offset));
      setMetadata(db, "last_success_at", new Date().toISOString());
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
    const invalid = result.invalid + transportInvalid + Number(cursor.invalid || 0);
    const finishedAt = new Date().toISOString();
    db.prepare(`UPDATE collection_runs SET finished_at=?,status='succeeded',source_rows=?,
      inserted_rows=?,duplicate_rows=?,invalid_rows=? WHERE id=?`).run(
      finishedAt, events.length, result.inserted, result.duplicates, invalid, runId,
    );
    const summary = {
      status: "succeeded",
      run_id: runId,
      database: databasePath,
      source_rows: events.length,
      inserted_rows: result.inserted,
      duplicate_rows: result.duplicates,
      invalid_rows: invalid,
    };
    db.close();
    return summary;
  } catch (error) {
    const safeError = text(error?.message || error, 500) || "Unknown collection error";
    db.prepare("UPDATE collection_runs SET finished_at=?,status='failed',error=? WHERE id=?")
      .run(new Date().toISOString(), safeError, runId);
    db.close();
    throw new Error(safeError);
  }
}

export function queryEvents(databasePath = defaultDatabasePath, options = {}) {
  const db = openDatabase(databasePath);
  const hours = Math.min(24 * 3650, Math.max(1, Number(options.hours) || 24));
  const limit = Math.min(1000, Math.max(1, Number(options.limit) || 100));
  const since = new Date(Date.now() - hours * 3_600_000).toISOString();
  const conditions = ["occurred_at>=?"];
  const parameters = [since];
  if (options.action) {
    conditions.push("lower(action)=lower(?)");
    parameters.push(text(options.action, 40));
  }
  if (options.signatureId !== undefined && options.signatureId !== null) {
    conditions.push("signature_id=?");
    parameters.push(integer(options.signatureId));
  }
  parameters.push(limit);
  const rows = db.prepare(`
    SELECT occurred_at,action,category,severity,signature_id,signature,src_ip,src_port,
      dest_ip,dest_port,protocol,app_protocol,flow_id,unifi_category,classification,
      signature_type,suricata_version,collected_at
    FROM security_events
    WHERE ${conditions.join(" AND ")}
    ORDER BY occurred_at DESC
    LIMIT ?
  `).all(...parameters);
  db.close();
  return rows;
}

export function status(databasePath = defaultDatabasePath) {
  const db = openDatabase(databasePath);
  const integrity = db.prepare("PRAGMA quick_check").all().map((row) => Object.values(row)[0]);
  const totals = db.prepare(`SELECT count(*) AS total,
    sum(CASE WHEN lower(coalesce(action,''))='blocked' THEN 1 ELSE 0 END) AS blocked,
    min(occurred_at) AS first_event_at,max(occurred_at) AS last_event_at FROM security_events`).get();
  const lastRun = db.prepare(`SELECT started_at,finished_at,status,source_rows,inserted_rows,
    duplicate_rows,invalid_rows,error FROM collection_runs ORDER BY started_at DESC LIMIT 1`).get() || null;
  const topSignatures = db.prepare(`SELECT signature_id,signature,action,count(*) AS occurrences,
    max(occurred_at) AS last_seen_at FROM security_events
    WHERE occurred_at>=? GROUP BY signature_id,signature,action
    ORDER BY occurrences DESC,last_seen_at DESC LIMIT 10`).all(new Date(Date.now() - 86_400_000).toISOString());
  const result = {
    database: databasePath,
    database_check: integrity.length === 1 && integrity[0] === "ok" ? "ok" : integrity,
    schema_version: getMetadata(db, "schema_version"),
    contains_raw_payload: getMetadata(db, "contains_raw_payload") === "true",
    total_events: Number(totals.total || 0),
    blocked_events: Number(totals.blocked || 0),
    first_event_at: totals.first_event_at || null,
    last_event_at: totals.last_event_at || null,
    last_collection: lastRun,
    top_signatures_last_24h: topSignatures,
  };
  db.close();
  return result;
}

function parseArguments(argv) {
  const result = { command: argv[0] || "status" };
  for (let index = 1; index < argv.length; index += 1) {
    const key = argv[index];
    const value = argv[index + 1];
    if (key === "--database" && value) { result.database = path.resolve(value); index += 1; }
    else if (key === "--hours" && value) { result.hours = Number(value); index += 1; }
    else if (key === "--limit" && value) { result.limit = Number(value); index += 1; }
    else if (key === "--action" && value) { result.action = value; index += 1; }
    else if (key === "--signature-id" && value) { result.signatureId = Number(value); index += 1; }
    else throw new Error(`Unknown argument: ${key}`);
  }
  return result;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const databasePath = options.database || defaultDatabasePath;
  let result;
  if (options.command === "sync") result = sync(databasePath);
  else if (options.command === "status") result = status(databasePath);
  else if (options.command === "query") result = queryEvents(databasePath, options);
  else throw new Error(`Unknown command: ${options.command}`);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : null;
if (invokedPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${text(error?.message || error, 500) || "UniFi security log error"}\n`);
    process.exitCode = 1;
  });
}

export { defaultDatabasePath };
