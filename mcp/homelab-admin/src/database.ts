import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";

const moduleDirectory = path.dirname(fileURLToPath(import.meta.url));
export const repositoryRoot = path.resolve(moduleDirectory, "..", "..", "..");
const localAppData = process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local");
export const knowledgeRoot = path.join(localAppData, "CodexAdmin", "homelab");
export const knowledgeDatabasePath = path.join(knowledgeRoot, "homelab-ops.sqlite3");
export const knowledgeBackupRoot = path.join(knowledgeRoot, "backups");
export const siteRoot = path.resolve(
  process.env.CODEX_ADMIN_SITE_ROOT?.trim() || path.join(localAppData, "CodexAdmin", "site"),
);

if (siteRoot === repositoryRoot || siteRoot.startsWith(`${repositoryRoot}${path.sep}`)) {
  throw new Error("CODEX_ADMIN_SITE_ROOT must remain outside the Git repository");
}

const overlayPaths = new Set([
  "config/daily-log-review.json",
  "config/job-definitions.json",
]);

function resolveDataPath(relativePath: string): string {
  const normalized = relativePath.replaceAll("\\", "/");
  const repositoryPath = path.resolve(repositoryRoot, normalized);
  if (!repositoryPath.startsWith(`${repositoryRoot}${path.sep}`)) {
    throw new Error(`Data path escaped the repository: ${relativePath}`);
  }
  if (normalized.startsWith("inventory/") || overlayPaths.has(normalized)) {
    const sitePath = path.resolve(siteRoot, normalized);
    if (!sitePath.startsWith(`${siteRoot}${path.sep}`)) {
      throw new Error(`Data path escaped the site overlay: ${relativePath}`);
    }
    if (existsSync(sitePath)) return sitePath;
  }
  return repositoryPath;
}

type JsonObject = Record<string, unknown>;

type FactInput = {
  system_id?: string | null;
  category: string;
  fact_key: string;
  fact_value: string;
  source: string;
  confidence: number;
  valid_for_hours?: number | null;
  observed_at?: string | null;
};

type ObservationInput = {
  system_id?: string | null;
  kind: string;
  status: "ok" | "warning" | "critical" | "unknown";
  summary: string;
  details?: string | null;
  source: string;
  confidence: number;
  valid_for_hours: number;
  observed_at?: string | null;
};

type ChangeInput = {
  system_id?: string | null;
  requested_by?: string;
  approval_reference?: string | null;
  summary: string;
  before_state?: string | null;
  after_state?: string | null;
  verification: string;
  rollback: string;
  result: "succeeded" | "failed" | "rolled_back" | "partial";
  occurred_at?: string | null;
};

type IncidentInput = {
  id?: string | null;
  system_id?: string | null;
  title: string;
  severity: "low" | "medium" | "high" | "critical";
  status: "open" | "monitoring" | "resolved";
  symptoms: string;
  root_cause?: string | null;
  remediation?: string | null;
  prevention?: string | null;
  event_summary?: string | null;
  event_details?: string | null;
  source: string;
  occurred_at?: string | null;
};

type DecisionInput = {
  id?: string | null;
  system_id?: string | null;
  title: string;
  context: string;
  decision: string;
  rationale: string;
  alternatives?: string | null;
  status: "proposed" | "active" | "superseded";
  source: string;
  decided_at?: string | null;
};

type MaintenanceInput = {
  id: string;
  system_id?: string | null;
  category: string;
  title: string;
  status: "open" | "scheduled" | "completed" | "deferred";
  due_at?: string | null;
  interval_days?: number | null;
  verification?: string | null;
  notes?: string | null;
  source: string;
};

type AccessTestInput = {
  profile_id: string;
  result: "verified" | "failed";
  evidence: string;
  source: string;
  valid_for_hours?: number;
  tested_at?: string | null;
};

type LearningCandidateInput = {
  id?: string | null;
  system_id?: string | null;
  candidate_type: "runbook" | "skill" | "automation" | "policy" | "knowledge";
  title: string;
  trigger: string;
  proposed_change: string;
  evidence: string;
  validation_plan: string;
  source: string;
};

type LearningCandidateReviewInput = {
  id: string;
  action: "approve" | "reject" | "apply";
  review_reference: string;
  validation: string;
  applied_change_id?: string | null;
};

type TaskContractCreateInput = {
  id?: string | null;
  objective: string;
  success_criteria: string[];
  current_step?: string | null;
  source: string;
};

type TaskContractUpdateInput = {
  id: string;
  status: "active" | "waiting" | "blocked" | "completed" | "cancelled";
  current_step?: string | null;
  wait_reason?: string | null;
  wait_job_id?: string | null;
  verification?: string | null;
  source: string;
};

type ContextBootstrapOptions = {
  detail?: "compact" | "full";
  sync?: boolean;
};

const forbiddenMaterialPatterns: Array<[RegExp, string]> = [
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/i, "private key"],
  [/\botpauth:\/\//i, "TOTP provisioning URI"],
  [/\bPVEAPIToken\s*=/i, "Proxmox authorization token"],
  [/\bBearer\s+[A-Za-z0-9._~+\/-]{16,}/i, "authorization bearer value"],
  [/\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}/i, "API key"],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/, "JWT"],
  [/(?:password|passphrase|recovery[_ -]?code)\s*[:=]\s*\S{4,}/i, "credential value"],
];

function nowIso(): string {
  return new Date().toISOString();
}

function addHours(value: string, hours: number | null | undefined): string | null {
  if (hours === null || hours === undefined) return null;
  return new Date(new Date(value).getTime() + hours * 3_600_000).toISOString();
}

function readJson<T>(relativePath: string): T {
  return JSON.parse(readFileSync(resolveDataPath(relativePath), "utf8")) as T;
}

function sourceTimestamp(relativePath: string): string {
  return statSync(resolveDataPath(relativePath)).mtime.toISOString();
}

function assertText(value: string, field: string, maximum = 16_384): string {
  const normalized = value.trim();
  if (!normalized) throw new Error(`${field} is required`);
  if (normalized.length > maximum || normalized.includes("\0")) {
    throw new Error(`${field} is invalid`);
  }
  for (const [pattern, description] of forbiddenMaterialPatterns) {
    if (pattern.test(normalized)) {
      throw new Error(`${field} appears to contain ${description}; store only a DPAPI credential reference`);
    }
  }
  return normalized;
}

function optionalText(value: string | null | undefined, field: string, maximum = 16_384): string | null {
  if (value === null || value === undefined || !value.trim()) return null;
  return assertText(value, field, maximum);
}

function compactText(value: unknown, maximum = 500): string | null {
  if (value === null || value === undefined) return null;
  const normalized = String(value).trim();
  if (!normalized) return null;
  return normalized.length <= maximum ? normalized : `${normalized.slice(0, maximum - 1)}…`;
}

function assertThreadId(value: string): string {
  const normalized = assertText(value, "target_thread_id", 80);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(normalized)) {
    throw new Error("target_thread_id is invalid");
  }
  return normalized;
}

function dbValue(value: unknown): string | number | bigint | Uint8Array | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string" || typeof value === "number" || typeof value === "bigint") return value;
  if (typeof value === "boolean") return value ? 1 : 0;
  if (value instanceof Uint8Array) return value;
  return JSON.stringify(value);
}

function ensureSystem(db: DatabaseSync, systemId: string | null | undefined): void {
  if (!systemId) return;
  const row = db.prepare("SELECT id FROM systems WHERE id = ?").get(systemId);
  if (!row) throw new Error(`Unknown system_id: ${systemId}`);
}

function gitRevision(): string | null {
  try {
    const head = readFileSync(path.join(repositoryRoot, ".git", "HEAD"), "utf8").trim();
    if (!head.startsWith("ref: ")) return head;
    const refPath = head.slice(5);
    return readFileSync(path.join(repositoryRoot, ".git", refPath), "utf8").trim();
  } catch {
    return null;
  }
}

export function openKnowledgeDatabase(): DatabaseSync {
  mkdirSync(knowledgeRoot, { recursive: true });
  mkdirSync(knowledgeBackupRoot, { recursive: true });
  const db = new DatabaseSync(knowledgeDatabasePath);
  db.exec("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000;");
  const migrationRoot = path.join(repositoryRoot, "database", "migrations");
  const migrations = readdirSync(migrationRoot)
    .filter((name) => /^\d+_.*\.sql$/i.test(name))
    .sort((left, right) => left.localeCompare(right));
  for (const name of migrations) {
    const version = Number.parseInt(name.split("_", 1)[0], 10);
    let applied = false;
    try {
      applied = Boolean(db.prepare("SELECT 1 FROM schema_migrations WHERE version = ?").get(version));
    } catch {
      applied = false;
    }
    if (applied) continue;
    db.exec("BEGIN IMMEDIATE");
    try {
      db.exec(readFileSync(path.join(migrationRoot, name), "utf8"));
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw new Error(`Knowledge migration ${name} failed`, { cause: error });
    }
  }
  return db;
}

function upsertMetadata(db: DatabaseSync, key: string, value: string): void {
  const timestamp = nowIso();
  db.prepare(`
    INSERT INTO metadata(key, value, updated_at) VALUES (?, ?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
  `).run(key, value, timestamp);
}

function syncSystems(db: DatabaseSync): void {
  type Inventory = { workstation: JsonObject; services: Record<string, JsonObject> };
  const inventory = readJson<Inventory>("inventory/services.json");
  const observedAt = sourceTimestamp("inventory/services.json");
  const timestamp = nowIso();
  const upsert = db.prepare(`
    INSERT INTO systems(
      id, name, kind, location, parent_system_id, stable_identifier, criticality,
      lifecycle, source, observed_at, last_verified_at, valid_until, confidence, notes, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', 'inventory/services.json', ?, ?, NULL, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      name = excluded.name, kind = excluded.kind, location = excluded.location,
      parent_system_id = excluded.parent_system_id, stable_identifier = excluded.stable_identifier,
      criticality = excluded.criticality, source = excluded.source,
      observed_at = excluded.observed_at, confidence = excluded.confidence,
      notes = excluded.notes, lifecycle = 'active', updated_at = excluded.updated_at
  `);

  const workstation = inventory.workstation;
  upsert.run(
    "admin_workstation",
    String(workstation.hostname ?? "Codex admin VM"),
    "virtual_machine",
    "management_network",
    null,
    String(workstation.hostname ?? ""),
    "critical",
    observedAt,
    observedAt,
    1,
    String(workstation.notes ?? "Dedicated Codex admin VM"),
    timestamp,
  );

  const kindMap: Record<string, string> = {
    proxmox: "hypervisor",
    home_assistant: "virtual_machine",
    reverse_proxy: "container",
    unifi: "gateway",
  };
  const nameMap: Record<string, string> = {
    proxmox: "Proxmox",
    home_assistant: "Home Assistant",
    reverse_proxy: "Nginx Proxy Manager",
    unifi: "UniFi Dream Machine Primary Site",
  };
  for (const [id, service] of Object.entries(inventory.services)) {
    const stableIdentifier = String(
      service.console_host_id ?? service.hardware_id ?? service.vmid ?? service.detected_common_name ?? id,
    );
    const parent = id === "home_assistant" || id === "reverse_proxy" ? "proxmox" : null;
    const location = id === "unifi" ? String(service.detected_name ?? "Primary Site") : "management_network";
    const criticality = id === "proxmox" || id === "unifi" ? "critical" : "high";
    upsert.run(
      id,
      nameMap[id] ?? id,
      kindMap[id] ?? "service_host",
      location,
      parent,
      stableIdentifier,
      criticality,
      observedAt,
      observedAt,
      0.95,
      null,
      timestamp,
    );

    for (const [key, rawValue] of Object.entries(service)) {
      if (rawValue === null || typeof rawValue === "object") continue;
      const factId = `inventory:${id}:${key}`;
      db.prepare(`
        INSERT INTO facts(
          id, system_id, category, fact_key, fact_value, source, observed_at,
          last_verified_at, valid_until, confidence, status, supersedes_id, updated_at
        ) VALUES (?, ?, 'inventory', ?, ?, 'inventory/services.json', ?, ?, NULL, 0.95, 'active', NULL, ?)
        ON CONFLICT(id) DO UPDATE SET
          fact_value = excluded.fact_value, observed_at = excluded.observed_at,
          last_verified_at = excluded.last_verified_at, status = 'active', updated_at = excluded.updated_at
      `).run(factId, id, key, String(rawValue), observedAt, observedAt, timestamp);
    }
  }

  const structuredSystemsPath = "inventory/systems.json";
  if (existsSync(resolveDataPath(structuredSystemsPath))) {
    type SystemInventory = { systems: Array<Record<string, unknown>> };
    const structuredSystems = readJson<SystemInventory>(structuredSystemsPath);
    const structuredObservedAt = sourceTimestamp(structuredSystemsPath);
    const structuredUpsert = db.prepare(`
      INSERT INTO systems(
        id, name, kind, location, parent_system_id, stable_identifier, criticality,
        lifecycle, source, observed_at, last_verified_at, valid_until, confidence, notes, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'inventory/systems.json', ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name, kind = excluded.kind, location = excluded.location,
        parent_system_id = excluded.parent_system_id, stable_identifier = excluded.stable_identifier,
        criticality = excluded.criticality, lifecycle = excluded.lifecycle, source = excluded.source,
        observed_at = excluded.observed_at, last_verified_at = excluded.last_verified_at,
        valid_until = excluded.valid_until, confidence = excluded.confidence,
        notes = excluded.notes, updated_at = excluded.updated_at
    `);
    for (const item of structuredSystems.systems) {
      structuredUpsert.run(
        dbValue(item.id), dbValue(item.name), dbValue(item.kind), dbValue(item.location),
        dbValue(item.parent_system_id), dbValue(item.stable_identifier),
        dbValue(item.criticality ?? "normal"), dbValue(item.lifecycle ?? "active"),
        structuredObservedAt, dbValue(item.last_verified_at ?? structuredObservedAt),
        dbValue(item.valid_until), dbValue(item.confidence ?? 0.95), dbValue(item.notes), timestamp,
      );
    }
  }

  const workstationFacts: Record<string, unknown> = inventory.workstation;
  for (const [key, rawValue] of Object.entries(workstationFacts)) {
    if (rawValue === null || typeof rawValue === "object") continue;
    db.prepare(`
      INSERT INTO facts(
        id, system_id, category, fact_key, fact_value, source, observed_at,
        last_verified_at, valid_until, confidence, status, supersedes_id, updated_at
      ) VALUES (?, 'admin_workstation', 'inventory', ?, ?, 'inventory/services.json', ?, ?, NULL, 1, 'active', NULL, ?)
      ON CONFLICT(id) DO UPDATE SET
        fact_value = excluded.fact_value, observed_at = excluded.observed_at,
        last_verified_at = excluded.last_verified_at, status = 'active', updated_at = excluded.updated_at
    `).run(`inventory:admin_workstation:${key}`, key, String(rawValue), observedAt, observedAt, timestamp);
  }

  const interfaceUpsert = db.prepare(`
    INSERT INTO interfaces(
      id, system_id, purpose, protocol, address, port, username, tls_fingerprint_sha256,
      ssh_host_key_fingerprint, credential_ref, source, observed_at, last_verified_at,
      valid_until, confidence, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, 'inventory/services.json', ?, ?, NULL, 0.95, ?)
    ON CONFLICT(id) DO UPDATE SET
      protocol = excluded.protocol, address = excluded.address, port = excluded.port,
      username = excluded.username, tls_fingerprint_sha256 = excluded.tls_fingerprint_sha256,
      credential_ref = excluded.credential_ref, observed_at = excluded.observed_at,
      last_verified_at = excluded.last_verified_at, updated_at = excluded.updated_at
  `);
  for (const [id, service] of Object.entries(inventory.services)) {
    for (const [field, purpose] of [["base_url", "management"], ["ssh_url", "ssh_host"], ["ssh_app_url", "ssh_app"]] as const) {
      const raw = service[field];
      if (typeof raw !== "string" || !raw) continue;
      const uri = new URL(raw);
      const port = uri.port ? Number(uri.port) : uri.protocol === "https:" ? 443 : uri.protocol === "ssh:" ? 22 : 80;
      const credentialRef = field === "base_url" ? service.credential_ref : service.ssh_credential_ref;
      interfaceUpsert.run(
        `${id}:${purpose}`,
        id,
        purpose,
        uri.protocol.replace(":", ""),
        uri.hostname,
        port,
        field === "base_url" ? null : String(service.ssh_user ?? ""),
        field === "base_url" ? String(service.certificate_sha256 ?? "") || null : null,
        typeof credentialRef === "string" ? credentialRef : null,
        observedAt,
        observedAt,
        timestamp,
      );
    }
  }

  const explicitInterfacesPath = "inventory/interfaces.json";
  if (existsSync(resolveDataPath(explicitInterfacesPath))) {
    type InterfaceInventory = { interfaces: Array<Record<string, unknown>> };
    const explicitInterfaces = readJson<InterfaceInventory>(explicitInterfacesPath);
    const interfaceObservedAt = sourceTimestamp(explicitInterfacesPath);
    const explicitInterfaceUpsert = db.prepare(`
      INSERT INTO interfaces(
        id, system_id, purpose, protocol, address, port, username, tls_fingerprint_sha256,
        ssh_host_key_fingerprint, credential_ref, source, observed_at, last_verified_at,
        valid_until, confidence, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'inventory/interfaces.json', ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        system_id = excluded.system_id, purpose = excluded.purpose, protocol = excluded.protocol,
        address = excluded.address, port = excluded.port, username = excluded.username,
        tls_fingerprint_sha256 = excluded.tls_fingerprint_sha256,
        ssh_host_key_fingerprint = excluded.ssh_host_key_fingerprint,
        credential_ref = excluded.credential_ref, source = excluded.source,
        observed_at = excluded.observed_at, last_verified_at = excluded.last_verified_at,
        valid_until = excluded.valid_until, confidence = excluded.confidence,
        updated_at = excluded.updated_at
    `);
    for (const item of explicitInterfaces.interfaces) {
      explicitInterfaceUpsert.run(
        dbValue(item.id), dbValue(item.system_id), dbValue(item.purpose), dbValue(item.protocol),
        dbValue(item.address), dbValue(item.port), dbValue(item.username),
        dbValue(item.tls_fingerprint_sha256), dbValue(item.ssh_host_key_fingerprint),
        dbValue(item.credential_ref), interfaceObservedAt,
        dbValue(item.last_verified_at ?? interfaceObservedAt), dbValue(item.valid_until),
        dbValue(item.confidence ?? 0.9), timestamp,
      );
    }
  }
}

function syncStructuredInventory(db: DatabaseSync): void {
  const timestamp = nowIso();

  const serviceCatalogPath = "inventory/service-catalog.json";
  if (existsSync(resolveDataPath(serviceCatalogPath))) {
    type ServiceInventory = { services: Array<Record<string, unknown>> };
    const serviceCatalog = readJson<ServiceInventory>(serviceCatalogPath);
    const serviceObservedAt = sourceTimestamp(serviceCatalogPath);
    const serviceUpsert = db.prepare(`
      INSERT INTO services(
        id, system_id, name, product, version, desired_state, observed_state,
        management_interface_id, source, observed_at, last_verified_at,
        valid_until, confidence, notes, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'inventory/service-catalog.json', ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        system_id = excluded.system_id, name = excluded.name, product = excluded.product,
        version = excluded.version, desired_state = excluded.desired_state,
        observed_state = excluded.observed_state,
        management_interface_id = excluded.management_interface_id,
        source = excluded.source, observed_at = excluded.observed_at,
        last_verified_at = excluded.last_verified_at, valid_until = excluded.valid_until,
        confidence = excluded.confidence, notes = excluded.notes,
        updated_at = excluded.updated_at
    `);
    for (const item of serviceCatalog.services) {
      serviceUpsert.run(
        dbValue(item.id), dbValue(item.system_id), dbValue(item.name), dbValue(item.product),
        dbValue(item.version), dbValue(item.desired_state), dbValue(item.observed_state),
        dbValue(item.management_interface_id), serviceObservedAt,
        dbValue(item.last_verified_at ?? serviceObservedAt), dbValue(item.valid_until),
        dbValue(item.confidence ?? 0.9), dbValue(item.notes), timestamp,
      );
    }
  }

  type AccessInventory = { profiles: Array<Record<string, unknown>> };
  const access = readJson<AccessInventory>("inventory/access-profiles.json");
  const accessSourceAt = sourceTimestamp("inventory/access-profiles.json");
  const accessUpsert = db.prepare(`
    INSERT INTO access_profiles(
      id, system_id, identity, method, scope, credential_ref, last_tested_at,
      test_result, revocation, source, notes, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'inventory/access-profiles.json', ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      system_id = excluded.system_id, identity = excluded.identity, method = excluded.method,
      scope = excluded.scope, credential_ref = excluded.credential_ref,
      last_tested_at = CASE
        WHEN COALESCE(access_profiles.last_tested_at, '') > COALESCE(excluded.last_tested_at, '')
          THEN access_profiles.last_tested_at ELSE excluded.last_tested_at END,
      test_result = CASE
        WHEN COALESCE(access_profiles.last_tested_at, '') > COALESCE(excluded.last_tested_at, '')
          THEN access_profiles.test_result ELSE excluded.test_result END,
      revocation = excluded.revocation, notes = excluded.notes,
      updated_at = CASE WHEN access_profiles.updated_at > excluded.updated_at
        THEN access_profiles.updated_at ELSE excluded.updated_at END
  `);
  for (const item of access.profiles) {
    accessUpsert.run(
      dbValue(item.id), dbValue(item.system_id), dbValue(item.identity), dbValue(item.method), dbValue(item.scope),
      dbValue(item.credential_ref), dbValue(item.last_tested_at), dbValue(item.test_result),
      dbValue(item.revocation), dbValue(item.notes), accessSourceAt,
    );
  }

  type CapabilityInventory = { capabilities: Array<Record<string, unknown>> };
  const capabilities = readJson<CapabilityInventory>("inventory/capabilities.json");
  const capabilitySourceAt = sourceTimestamp("inventory/capabilities.json");
  const capabilityUpsert = db.prepare(`
    INSERT INTO capabilities(
      id, system_id, name, access_level, access_profile_id, last_tested_at,
      test_result, evidence, source, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'inventory/capabilities.json', ?)
    ON CONFLICT(id) DO UPDATE SET
      system_id = excluded.system_id, name = excluded.name, access_level = excluded.access_level,
      access_profile_id = excluded.access_profile_id,
      last_tested_at = CASE
        WHEN COALESCE(capabilities.last_tested_at, '') > COALESCE(excluded.last_tested_at, '')
          THEN capabilities.last_tested_at ELSE excluded.last_tested_at END,
      test_result = CASE
        WHEN COALESCE(capabilities.last_tested_at, '') > COALESCE(excluded.last_tested_at, '')
          THEN capabilities.test_result ELSE excluded.test_result END,
      evidence = CASE
        WHEN COALESCE(capabilities.last_tested_at, '') > COALESCE(excluded.last_tested_at, '')
          THEN capabilities.evidence ELSE excluded.evidence END,
      updated_at = CASE WHEN capabilities.updated_at > excluded.updated_at
        THEN capabilities.updated_at ELSE excluded.updated_at END
  `);
  for (const item of capabilities.capabilities) {
    capabilityUpsert.run(
      dbValue(item.id), dbValue(item.system_id), dbValue(item.name), dbValue(item.access_level), dbValue(item.access_profile_id),
      dbValue(item.last_tested_at), dbValue(item.test_result), dbValue(item.evidence), capabilitySourceAt,
    );
  }

  type DependencyInventory = { dependencies: Array<Record<string, unknown>> };
  const dependencies = readJson<DependencyInventory>("inventory/dependencies.json");
  const dependencyUpsert = db.prepare(`
    INSERT INTO dependencies(
      id, from_system_id, to_system_id, relationship, source, observed_at,
      last_verified_at, confidence, notes, updated_at
    ) VALUES (?, ?, ?, ?, 'inventory/dependencies.json', ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      from_system_id = excluded.from_system_id, to_system_id = excluded.to_system_id,
      relationship = excluded.relationship, observed_at = excluded.observed_at,
      last_verified_at = excluded.last_verified_at, confidence = excluded.confidence,
      notes = excluded.notes, updated_at = excluded.updated_at
  `);
  const dependencyObservedAt = sourceTimestamp("inventory/dependencies.json");
  for (const item of dependencies.dependencies) {
    dependencyUpsert.run(
      dbValue(item.id), dbValue(item.from_system_id), dbValue(item.to_system_id), dbValue(item.relationship),
      dependencyObservedAt, dependencyObservedAt, dbValue(item.confidence ?? 0.9),
      dbValue(item.notes), timestamp,
    );
  }

  type MaintenanceInventory = { items: Array<Record<string, unknown>> };
  const maintenance = readJson<MaintenanceInventory>("inventory/maintenance.json");
  const maintenanceSourceAt = sourceTimestamp("inventory/maintenance.json");
  const maintenanceUpsert = db.prepare(`
    INSERT INTO maintenance(
      id, system_id, category, title, status, due_at, interval_days,
      verification, notes, source, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'inventory/maintenance.json', ?)
    ON CONFLICT(id) DO UPDATE SET
      system_id = excluded.system_id, category = excluded.category, title = excluded.title,
      status = CASE WHEN maintenance.updated_at > excluded.updated_at THEN maintenance.status ELSE excluded.status END,
      due_at = CASE WHEN maintenance.updated_at > excluded.updated_at THEN maintenance.due_at ELSE excluded.due_at END,
      interval_days = excluded.interval_days, verification = excluded.verification, notes = excluded.notes,
      source = CASE WHEN maintenance.updated_at > excluded.updated_at THEN maintenance.source ELSE excluded.source END,
      updated_at = CASE WHEN maintenance.updated_at > excluded.updated_at THEN maintenance.updated_at ELSE excluded.updated_at END
  `);
  for (const item of maintenance.items) {
    maintenanceUpsert.run(
      dbValue(item.id), dbValue(item.system_id), dbValue(item.category), dbValue(item.title), dbValue(item.status),
      dbValue(item.due_at), dbValue(item.interval_days), dbValue(item.verification),
      dbValue(item.notes), maintenanceSourceAt,
    );
  }
}

function syncKnowledgeDocuments(db: DatabaseSync): void {
  const categoryByName: Record<string, string> = {
    "AGENTS.md": "policy",
    "CHANGELOG.md": "change_history",
    "README.md": "overview",
    "access-setup.md": "access",
    "admin-identities.md": "access",
    "daily-log-review.md": "monitoring",
    "infrastructure-inventory.md": "inventory",
    "job-engine.md": "automation",
    "knowledge-base.md": "knowledge",
    "recovery.md": "recovery",
    "secret-intake.md": "secrets_policy",
    "subagent-policy.md": "policy",
    "system-map.md": "topology",
    "windows-autologon.md": "startup",
    "codex-autostart.md": "startup",
  };
  const relativePaths = ["AGENTS.md", "CHANGELOG.md", "README.md"];
  const docsRoot = path.join(repositoryRoot, "docs");
  if (existsSync(docsRoot)) {
    relativePaths.push(...readdirSync(docsRoot)
      .filter((name) => name.toLowerCase().endsWith(".md"))
      .sort()
      .map((name) => path.posix.join("docs", name)));
  }
  const documents: Array<[string, string, string]> = relativePaths.map((relativePath) => {
    const name = path.basename(relativePath);
    const stem = name.replace(/\.md$/i, "").toLowerCase();
    const id = relativePath === "AGENTS.md" ? "repo:agents"
      : relativePath === "CHANGELOG.md" ? "repo:changelog"
        : relativePath === "README.md" ? "repo:readme"
          : `repo:${stem}`;
    return [id, categoryByName[name] ?? "runbook", relativePath];
  });
  const upsert = db.prepare(`
    INSERT INTO knowledge_entries(
      id, system_id, category, title, content, source_path, source_hash,
      last_verified_at, confidence, updated_at
    ) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, 0.9, ?)
    ON CONFLICT(id) DO UPDATE SET
      category = excluded.category, title = excluded.title, content = excluded.content,
      source_hash = excluded.source_hash, last_verified_at = excluded.last_verified_at,
      confidence = excluded.confidence, updated_at = excluded.updated_at
  `);
  for (const [id, category, relativePath] of documents) {
    const absolutePath = path.join(repositoryRoot, relativePath);
    if (!existsSync(absolutePath)) continue;
    const content = readFileSync(absolutePath, "utf8");
    const hash = createHash("sha256").update(content).digest("hex");
    const verifiedAt = statSync(absolutePath).mtime.toISOString();
    upsert.run(id, category, path.basename(relativePath), content, relativePath, hash, verifiedAt, nowIso());
  }
  const activeIds = documents.map(([id]) => id);
  const placeholders = activeIds.map(() => "?").join(", ");
  db.prepare(`DELETE FROM knowledge_entries WHERE id LIKE 'repo:%' AND id NOT IN (${placeholders})`).run(...activeIds);
}

export function synchronizeKnowledgeBase(db: DatabaseSync): JsonObject {
  db.exec("BEGIN IMMEDIATE");
  try {
    syncSystems(db);
    syncStructuredInventory(db);
    syncKnowledgeDocuments(db);
    upsertMetadata(db, "role", "Dedicated administrator for the user's authorized homelab from this Windows VM");
    upsertMetadata(db, "last_repository_sync_at", nowIso());
    upsertMetadata(db, "source_revision", gitRevision() ?? "working-tree");
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return databaseStatistics(db);
}

export function databaseStatistics(db: DatabaseSync): JsonObject {
  const counts: Record<string, number> = {};
  for (const table of [
    "systems", "interfaces", "services", "dependencies", "access_profiles", "capabilities",
    "facts", "observations", "changes", "incidents", "maintenance",
    "decisions", "incident_events", "knowledge_entries", "learning_candidates",
    "task_contracts", "task_contract_events",
  ]) {
    const row = db.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get() as { count: number };
    counts[table] = Number(row.count);
  }
  return {
    database_path: knowledgeDatabasePath,
    schema_version: Number((db.prepare("SELECT MAX(version) AS version FROM schema_migrations").get() as { version?: number }).version ?? 0),
    counts,
    last_repository_sync_at: (db.prepare("SELECT value FROM metadata WHERE key = 'last_repository_sync_at'").get() as { value?: string } | undefined)?.value ?? null,
  };
}

export function freshnessReport(db: DatabaseSync): JsonObject {
  const now = nowIso();
  const staleFacts = db.prepare(`
    SELECT id, system_id, category, fact_key, valid_until, confidence
    FROM facts WHERE status = 'active' AND valid_until IS NOT NULL AND valid_until <= ?
    ORDER BY valid_until
  `).all(now);
  const staleAccess = db.prepare(`
    SELECT id, system_id, identity, method, last_tested_at, test_result
    FROM access_profiles
    WHERE test_result != 'verified'
       OR last_tested_at IS NULL
       OR last_tested_at <= datetime(?, '-7 days')
    ORDER BY system_id, id
  `).all(now);
  const expiredObservations = db.prepare(`
    WITH ranked AS (
      SELECT id, system_id, kind, status, summary, observed_at, valid_until, confidence,
             ROW_NUMBER() OVER (
               PARTITION BY COALESCE(system_id, ''), kind
               ORDER BY observed_at DESC, recorded_at DESC, id DESC
             ) AS position
      FROM observations
    )
    SELECT id, system_id, kind, status, summary, observed_at, valid_until, confidence
    FROM ranked
    WHERE position = 1 AND valid_until <= ?
    ORDER BY valid_until, system_id, kind
  `).all(now);
  return {
    generated_at: now,
    stale_facts: staleFacts,
    stale_access_profiles: staleAccess,
    expired_observations: expiredObservations,
    expired_observation_count: expiredObservations.length,
    rule: "Reverify stale or low-confidence data before consequential changes",
  };
}

export function freshnessSummary(db: DatabaseSync): JsonObject {
  const now = nowIso();
  const counts = db.prepare(`
    SELECT
      (SELECT COUNT(*) FROM facts
       WHERE status='active' AND valid_until IS NOT NULL AND valid_until <= ?) AS stale_fact_count,
      (SELECT COUNT(*) FROM access_profiles
       WHERE test_result != 'verified' OR last_tested_at IS NULL OR last_tested_at <= datetime(?, '-7 days')) AS stale_access_profile_count,
      (SELECT COUNT(*) FROM (
        SELECT ROW_NUMBER() OVER (
          PARTITION BY COALESCE(system_id, ''), kind
          ORDER BY observed_at DESC, recorded_at DESC, id DESC
        ) AS position, valid_until
        FROM observations
      ) ranked WHERE position=1 AND valid_until <= ?) AS expired_observation_count
  `).get(now, now, now) as Record<string, number>;
  const byStatusRows = db.prepare(`
    WITH ranked AS (
      SELECT status, valid_until,
             ROW_NUMBER() OVER (
               PARTITION BY COALESCE(system_id, ''), kind
               ORDER BY observed_at DESC, recorded_at DESC, id DESC
             ) AS position
      FROM observations
    )
    SELECT COALESCE(status, 'unknown') AS status, COUNT(*) AS count
    FROM ranked WHERE position=1 AND valid_until <= ? GROUP BY COALESCE(status, 'unknown')
  `).all(now) as Array<Record<string, unknown>>;
  const bySystemRows = db.prepare(`
    WITH ranked AS (
      SELECT COALESCE(system_id, 'unscoped') AS system_id, valid_until,
             ROW_NUMBER() OVER (
               PARTITION BY COALESCE(system_id, ''), kind
               ORDER BY observed_at DESC, recorded_at DESC, id DESC
             ) AS position
      FROM observations
    )
    SELECT system_id, COUNT(*) AS count
    FROM ranked WHERE position=1 AND valid_until <= ?
    GROUP BY system_id ORDER BY count DESC, system_id LIMIT 8
  `).all(now);
  return {
    generated_at: now,
    stale_fact_count: Number(counts.stale_fact_count),
    stale_access_profile_count: Number(counts.stale_access_profile_count),
    expired_observation_count: Number(counts.expired_observation_count),
    expired_observations_by_status: Object.fromEntries(
      byStatusRows.map((row) => [String(row.status), Number(row.count)]),
    ),
    most_affected_systems: bySystemRows,
    detail_tool: "knowledge_freshness_report",
    rule: "Reverify stale or low-confidence data before consequential changes",
  };
}

function publicTaskContract(row: Record<string, unknown>): JsonObject {
  const { target_thread_id: _targetThreadId, success_criteria_json: criteriaJson, ...publicFields } = row;
  return {
    ...publicFields,
    success_criteria: JSON.parse(String(criteriaJson ?? "[]")),
  };
}

function persistContextSnapshot(db: DatabaseSync, context: JsonObject, generatedAt: string): void {
  db.prepare(`
    INSERT INTO context_snapshots(id, generated_at, content_json, source_revision, expires_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(randomUUID(), generatedAt, JSON.stringify(context), gitRevision(), addHours(generatedAt, 24));
  db.prepare(`
    DELETE FROM context_snapshots WHERE id NOT IN (
      SELECT id FROM context_snapshots ORDER BY generated_at DESC LIMIT 50
    )
  `).run();
}

function compactContextBootstrap(
  db: DatabaseSync,
  now: string,
  role: string,
  policy: JsonObject,
): JsonObject {
  const systems = db.prepare(`
    SELECT id,name,kind,location,parent_system_id,criticality,lifecycle
    FROM systems WHERE lifecycle != 'retired' ORDER BY criticality DESC,name
  `).all();
  const counts = db.prepare(`
    SELECT
      (SELECT COUNT(*) FROM systems WHERE lifecycle != 'retired') AS systems,
      (SELECT COUNT(*) FROM dependencies) AS dependencies,
      (SELECT COUNT(*) FROM services) AS services,
      (SELECT COUNT(*) FROM access_profiles) AS access_profiles,
      (SELECT COUNT(*) FROM capabilities) AS capabilities,
      (SELECT COUNT(*) FROM (
        SELECT 1 FROM observations WHERE valid_until > ?
        GROUP BY COALESCE(system_id, ''), kind
      )) AS current_observations
  `).get(now) as Record<string, number>;
  const maintenance = db.prepare(`
    SELECT id,system_id,category,title,status,due_at,interval_days
    FROM maintenance WHERE status IN ('open','scheduled')
    ORDER BY due_at IS NULL,due_at,title
  `).all();
  const incidents = db.prepare(`
    SELECT id,system_id,title,severity,status,opened_at
    FROM incidents WHERE status != 'resolved' ORDER BY severity DESC,opened_at LIMIT 20
  `).all();
  const recentResolutions = db.prepare(`
    SELECT id,system_id,title,severity,resolved_at,source
    FROM incidents WHERE status='resolved' ORDER BY resolved_at DESC LIMIT 5
  `).all().map((row) => ({
    ...(row as Record<string, unknown>),
    title: compactText((row as Record<string, unknown>).title, 300),
    source: compactText((row as Record<string, unknown>).source, 300),
    resolution_details_available_via: "incident_search",
  }));
  const recentChanges = db.prepare(`
    SELECT id,system_id,summary,result,occurred_at
    FROM changes ORDER BY occurred_at DESC LIMIT 5
  `).all().map((row) => ({
    ...(row as Record<string, unknown>),
    summary: compactText((row as Record<string, unknown>).summary, 500),
  }));
  const learningCandidates = db.prepare(`
    SELECT id,system_id,candidate_type,title,status,review_due_at,created_at,updated_at
    FROM learning_candidates WHERE status IN ('proposed','approved')
    ORDER BY review_due_at IS NULL,review_due_at,updated_at DESC LIMIT 10
  `).all();
  const learningAttention = db.prepare(`
    SELECT id,system_id,candidate_type,title,status,review_due_at,created_at,updated_at
    FROM learning_candidates
    WHERE status IN ('proposed','approved')
      AND review_due_at IS NOT NULL
      AND datetime(review_due_at) <= datetime(?, '+3 days')
    ORDER BY review_due_at LIMIT 10
  `).all(now).map((row) => learningCandidateWithDeadline(row as Record<string, unknown>));
  const taskContracts = db.prepare(`
    SELECT id,target_thread_id,objective,success_criteria_json,status,current_step,
           wait_reason,wait_job_id,verification,source,created_at,updated_at
    FROM task_contracts WHERE status IN ('active','waiting','blocked')
    ORDER BY updated_at DESC LIMIT 10
  `).all().map((row) => {
    const item = publicTaskContract(row as Record<string, unknown>);
    return {
      id: item.id,
      objective: compactText(item.objective, 500),
      success_criteria_count: Array.isArray(item.success_criteria) ? item.success_criteria.length : 0,
      status: item.status,
      current_step: compactText(item.current_step, 500),
      wait_reason: compactText(item.wait_reason, 500),
      wait_job_id: item.wait_job_id,
      updated_at: item.updated_at,
    };
  });
  const serviceAttention = db.prepare(`
    SELECT id,system_id,name,product,desired_state,observed_state,confidence,last_verified_at
    FROM services
    WHERE observed_state != desired_state OR confidence < 0.8
    ORDER BY confidence,last_verified_at LIMIT 12
  `).all();
  const accessAttention = db.prepare(`
    SELECT system_id,method,scope,last_tested_at,test_result
    FROM v_access_matrix
    WHERE COALESCE(test_result, '') != 'verified'
    ORDER BY last_tested_at IS NOT NULL,last_tested_at LIMIT 12
  `).all().map((row) => ({
    ...(row as Record<string, unknown>),
    scope: compactText((row as Record<string, unknown>).scope, 300),
  }));
  const observationAttention = db.prepare(`
    SELECT o.system_id,o.kind,o.status,o.summary,o.observed_at,o.valid_until,o.confidence
    FROM observations o
    JOIN (
      SELECT COALESCE(system_id, '') AS scope_id,kind,MAX(observed_at) AS latest
      FROM observations WHERE valid_until > ? GROUP BY COALESCE(system_id, ''),kind
    ) latest
      ON COALESCE(o.system_id, '')=latest.scope_id AND o.kind=latest.kind AND o.observed_at=latest.latest
    WHERE o.status != 'ok'
    ORDER BY o.observed_at DESC LIMIT 15
  `).all(now).map((row) => ({
    ...(row as Record<string, unknown>),
    summary: compactText((row as Record<string, unknown>).summary, 500),
  }));

  const context: JsonObject = {
    generated_at: now,
    expires_at: addHours(now, 24),
    detail: "compact",
    role,
    authoritative_repository: repositoryRoot,
    source_precedence: policy.source_precedence,
    database_rules: policy.write_rules,
    systems,
    counts: Object.fromEntries(Object.entries(counts).map(([key, value]) => [key, Number(value)])),
    open_maintenance: maintenance,
    open_incidents: incidents,
    recent_resolutions: recentResolutions,
    recent_changes: recentChanges,
    open_learning_candidates: learningCandidates,
    learning_attention: learningAttention,
    active_task_contracts: taskContracts,
    service_attention: serviceAttention,
    access_attention: accessAttention,
    observation_attention: observationAttention,
    freshness: freshnessSummary(db),
    instructions: [
      "Use this as orientation, not as a substitute for live verification of time-sensitive state.",
      "Never retrieve or store plaintext credentials in the knowledge database.",
      "Record stable knowledge as facts, temporary checks as observations, verified work as changes, and diagnosed problem lifecycles as incidents.",
      "Use system_context_get or system_context_batch_get for full target-specific details; request detail=full only for whole-environment audits.",
    ],
  };
  persistContextSnapshot(db, context, now);
  return context;
}

export function contextBootstrap(db: DatabaseSync, options: ContextBootstrapOptions = {}): JsonObject {
  const detail = options.detail ?? "compact";
  if (options.sync) synchronizeKnowledgeBase(db);
  const now = nowIso();
  const role = db.prepare("SELECT value FROM metadata WHERE key = 'role'").get() as { value: string };
  const policy = readJson<JsonObject>("config/knowledge-policy.json");
  if (detail === "compact") return compactContextBootstrap(db, now, role.value, policy);
  const systems = db.prepare(`
    SELECT id, name, kind, location, parent_system_id, stable_identifier,
           criticality, lifecycle, last_verified_at, confidence
    FROM systems WHERE lifecycle != 'retired' ORDER BY criticality DESC, name
  `).all();
  const access = db.prepare(`
    SELECT system_id, system_name, identity, method, scope, credential_ref,
           last_tested_at, test_result
    FROM v_access_matrix ORDER BY system_name, method
  `).all();
  const capabilities = db.prepare(`
    SELECT system_id, name, access_level, last_tested_at, test_result, evidence
    FROM capabilities ORDER BY system_id, name
  `).all();
  const serviceCatalog = db.prepare(`
    SELECT id, system_id, name, product, version, desired_state, observed_state,
           management_interface_id, last_verified_at, confidence, notes
    FROM services ORDER BY system_id, name
  `).all();
  const dependencies = db.prepare(`
    SELECT from_system_id, to_system_id, relationship, confidence, notes
    FROM dependencies ORDER BY from_system_id, relationship
  `).all();
  const maintenance = db.prepare(`
    SELECT id, system_id, category, title, status, due_at, interval_days,
           verification, notes
    FROM maintenance WHERE status IN ('open', 'scheduled') ORDER BY due_at IS NULL, due_at, title
  `).all();
  const recentChanges = db.prepare(`
    SELECT id, system_id, summary, verification, rollback, result, occurred_at
    FROM changes ORDER BY occurred_at DESC LIMIT 10
  `).all();
  const incidents = db.prepare(`
    SELECT id, system_id, title, severity, status, opened_at
    FROM incidents WHERE status != 'resolved' ORDER BY severity DESC, opened_at
  `).all();
  const recentResolutions = db.prepare(`
    SELECT id, system_id, title, severity, symptoms, root_cause, remediation,
           prevention, resolved_at, source
    FROM incidents WHERE status = 'resolved'
    ORDER BY resolved_at DESC LIMIT 10
  `).all();
  const learningCandidates = db.prepare(`
    SELECT id, system_id, candidate_type, title, trigger, proposed_change,
           evidence, validation_plan, status, source, review_due_at, created_at, updated_at
    FROM learning_candidates WHERE status IN ('proposed', 'approved')
    ORDER BY created_at DESC LIMIT 20
  `).all().map((row) => learningCandidateWithDeadline(row as Record<string, unknown>));
  const activeTaskContracts = db.prepare(`
    SELECT id, target_thread_id, objective, success_criteria_json, status,
           current_step, wait_reason, wait_job_id, verification, source,
           created_at, updated_at
    FROM task_contracts WHERE status IN ('active', 'waiting', 'blocked')
    ORDER BY updated_at DESC LIMIT 20
  `).all().map((row) => publicTaskContract(row as Record<string, unknown>));
  const currentObservations = db.prepare(`
    SELECT o.system_id, o.kind, o.status, o.summary, o.observed_at, o.valid_until, o.confidence
    FROM observations o
    JOIN (
      SELECT COALESCE(system_id, '') AS scope_id, kind, MAX(observed_at) AS latest
      FROM observations WHERE valid_until > ? GROUP BY COALESCE(system_id, ''), kind
    ) latest
    ON COALESCE(o.system_id, '') = latest.scope_id
      AND o.kind = latest.kind AND o.observed_at = latest.latest
    ORDER BY o.system_id, o.kind
  `).all(now);
  const baseContext: JsonObject = {
    generated_at: now,
    expires_at: addHours(now, 24),
    detail,
    role: role.value,
    authoritative_repository: repositoryRoot,
    source_precedence: policy.source_precedence,
    database_rules: policy.write_rules,
    open_maintenance: maintenance,
    open_incidents: incidents,
    recent_resolutions: recentResolutions,
    recent_changes: recentChanges,
    open_learning_candidates: learningCandidates,
    active_task_contracts: activeTaskContracts,
    freshness: detail === "full" ? freshnessReport(db) : freshnessSummary(db),
    instructions: [
      "Use this as orientation, not as a substitute for live verification of time-sensitive state.",
      "Never retrieve or store plaintext credentials in the knowledge database.",
      "Record stable knowledge as facts, temporary checks as observations, verified work as changes, and diagnosed problem lifecycles as incidents.",
      "Use system_context_get or system_context_batch_get for full target-specific details; request detail=full only for whole-environment audits.",
    ],
  };
  const context: JsonObject = detail === "full" ? {
    ...baseContext,
    systems,
    dependencies,
    service_catalog: serviceCatalog,
    access_profiles: access,
    verified_capabilities: capabilities,
    current_observations: currentObservations,
  } : {
    ...baseContext,
    systems: systems.map((row) => {
      const item = row as Record<string, unknown>;
      return {
        id: item.id,
        name: item.name,
        kind: item.kind,
        location: item.location,
        parent_system_id: item.parent_system_id,
        criticality: item.criticality,
        lifecycle: item.lifecycle,
      };
    }),
    counts: {
      systems: systems.length,
      dependencies: dependencies.length,
      services: serviceCatalog.length,
      access_profiles: access.length,
      capabilities: capabilities.length,
      current_observations: currentObservations.length,
    },
    open_maintenance: maintenance.map((row) => {
      const item = row as Record<string, unknown>;
      return {
        id: item.id,
        system_id: item.system_id,
        category: item.category,
        title: compactText(item.title, 300),
        status: item.status,
        due_at: item.due_at,
        interval_days: item.interval_days,
      };
    }),
    recent_resolutions: recentResolutions.slice(0, 5).map((row) => {
      const item = row as Record<string, unknown>;
      return {
        id: item.id,
        system_id: item.system_id,
        title: compactText(item.title, 300),
        severity: item.severity,
        resolved_at: item.resolved_at,
        source: compactText(item.source, 300),
        resolution_details_available_via: "incident_search",
      };
    }),
    recent_changes: recentChanges.slice(0, 5).map((row) => {
      const item = row as Record<string, unknown>;
      return {
        id: item.id,
        system_id: item.system_id,
        summary: compactText(item.summary, 500),
        result: item.result,
        occurred_at: item.occurred_at,
      };
    }),
    open_learning_candidates: learningCandidates.slice(0, 10).map((row) => {
      const item = row as Record<string, unknown>;
      return {
        id: item.id,
        system_id: item.system_id,
        candidate_type: item.candidate_type,
        title: compactText(item.title, 300),
        status: item.status,
        created_at: item.created_at,
        updated_at: item.updated_at,
      };
    }),
    active_task_contracts: activeTaskContracts.slice(0, 10).map((row) => {
      const item = row as Record<string, unknown>;
      return {
        id: item.id,
        objective: compactText(item.objective, 500),
        success_criteria_count: Array.isArray(item.success_criteria) ? item.success_criteria.length : 0,
        status: item.status,
        current_step: compactText(item.current_step, 500),
        wait_reason: compactText(item.wait_reason, 500),
        wait_job_id: item.wait_job_id,
        updated_at: item.updated_at,
      };
    }),
    service_attention: serviceCatalog.filter((row) => {
      const item = row as Record<string, unknown>;
      return item.observed_state !== item.desired_state || Number(item.confidence ?? 0) < 0.8;
    }).slice(0, 12).map((row) => {
      const item = row as Record<string, unknown>;
      return {
        id: item.id,
        system_id: item.system_id,
        name: item.name,
        product: item.product,
        desired_state: item.desired_state,
        observed_state: item.observed_state,
        confidence: item.confidence,
        last_verified_at: item.last_verified_at,
      };
    }),
    access_attention: access.filter((row) => String((row as Record<string, unknown>).test_result ?? "") !== "verified").slice(0, 12).map((row) => {
      const item = row as Record<string, unknown>;
      return {
        system_id: item.system_id,
        method: item.method,
        scope: compactText(item.scope, 300),
        last_tested_at: item.last_tested_at,
        test_result: item.test_result,
      };
    }),
    observation_attention: currentObservations.filter((row) => String((row as Record<string, unknown>).status ?? "") !== "ok").slice(0, 15).map((row) => {
      const item = row as Record<string, unknown>;
      return {
        system_id: item.system_id,
        kind: item.kind,
        status: item.status,
        summary: compactText(item.summary, 500),
        observed_at: item.observed_at,
        valid_until: item.valid_until,
        confidence: item.confidence,
      };
    }),
  };
  persistContextSnapshot(db, context, now);
  return context;
}

function ftsQuery(value: string): string {
  const tokens = value.trim().split(/\s+/).filter(Boolean).slice(0, 10);
  if (!tokens.length) throw new Error("query is required");
  return tokens.map((token) => `"${token.replaceAll('"', '""')}"`).join(" AND ");
}

export function searchKnowledge(db: DatabaseSync, query: string, limit: number): JsonObject {
  const safeQuery = assertText(query, "query", 200);
  if (!Number.isInteger(limit) || limit < 1 || limit > 25) throw new Error("limit is out of range");
  const knowledge = db.prepare(`
    SELECT ke.id, ke.system_id, ke.category, ke.title, ke.source_path,
           snippet(knowledge_fts, 1, '[', ']', ' … ', 28) AS excerpt,
           ke.last_verified_at, ke.confidence
    FROM knowledge_fts
    JOIN knowledge_entries ke ON ke.rowid = knowledge_fts.rowid
    WHERE knowledge_fts MATCH ?
    ORDER BY bm25(knowledge_fts)
    LIMIT ?
  `).all(ftsQuery(safeQuery), limit);
  const tokens = safeQuery.toLowerCase().split(/\s+/).filter(Boolean).slice(0, 10);
  const makeWhere = (columns: string[]): { clause: string; parameters: string[] } => ({
    clause: tokens.map(() => `(${columns.map((column) => `LOWER(COALESCE(${column}, '')) LIKE ?`).join(" OR ")})`).join(" AND "),
    parameters: tokens.flatMap((token) => columns.map(() => `%${token}%`)),
  });
  const factWhere = makeWhere(["fact_key", "fact_value"]);
  const facts = db.prepare(`
    SELECT id, system_id, category, fact_key, fact_value, source,
           last_verified_at, valid_until, confidence, status
    FROM facts
    WHERE status = 'active' AND ${factWhere.clause}
    ORDER BY confidence DESC, last_verified_at DESC LIMIT ?
  `).all(...factWhere.parameters, limit);
  const changeWhere = makeWhere(["summary", "before_state", "after_state", "verification", "rollback"]);
  const changes = db.prepare(`
    SELECT id, system_id, summary, before_state, after_state, verification, rollback,
           result, occurred_at
    FROM changes WHERE ${changeWhere.clause}
    ORDER BY occurred_at DESC LIMIT ?
  `).all(...changeWhere.parameters, limit);
  const incidentWhere = makeWhere(["title", "symptoms", "root_cause", "remediation", "prevention"]);
  const incidents = db.prepare(`
    SELECT id, system_id, title, severity, status, symptoms, root_cause, remediation,
           prevention, opened_at, resolved_at, source, updated_at
    FROM incidents WHERE ${incidentWhere.clause}
    ORDER BY CASE status WHEN 'open' THEN 0 WHEN 'monitoring' THEN 1 ELSE 2 END,
             updated_at DESC LIMIT ?
  `).all(...incidentWhere.parameters, limit);
  const decisionWhere = makeWhere(["title", "context", "decision", "rationale", "alternatives"]);
  const decisions = db.prepare(`
    SELECT id, system_id, title, context, decision, rationale, alternatives,
           status, decided_at, source
    FROM decisions WHERE ${decisionWhere.clause}
    ORDER BY decided_at DESC LIMIT ?
  `).all(...decisionWhere.parameters, limit);
  const maintenanceWhere = makeWhere(["title", "verification", "notes"]);
  const maintenance = db.prepare(`
    SELECT id, system_id, category, title, status, due_at, verification, notes, source
    FROM maintenance WHERE ${maintenanceWhere.clause}
    ORDER BY status, due_at LIMIT ?
  `).all(...maintenanceWhere.parameters, limit);
  const learningWhere = makeWhere(["title", "trigger", "proposed_change", "evidence", "validation_plan"]);
  const learningCandidates = db.prepare(`
    SELECT id, system_id, candidate_type, title, trigger, proposed_change,
           evidence, validation_plan, status, source, created_at, reviewed_at,
           review_reference, validation, applied_change_id, updated_at
    FROM learning_candidates WHERE ${learningWhere.clause}
    ORDER BY CASE status WHEN 'proposed' THEN 0 WHEN 'approved' THEN 1 ELSE 2 END,
             updated_at DESC LIMIT ?
  `).all(...learningWhere.parameters, limit);
  return { query: safeQuery, knowledge, facts, changes, incidents, decisions, maintenance, learning_candidates: learningCandidates };
}

export function searchIncidents(db: DatabaseSync, query: string, limit: number): JsonObject {
  const searched = searchKnowledge(db, query, limit) as { incidents: Array<Record<string, unknown>> };
  const incidents = searched.incidents.map((incident) => ({
    ...incident,
    events: db.prepare(`
      SELECT id, event_type, from_status, to_status, summary, details, source,
             occurred_at, recorded_at
      FROM incident_events WHERE incident_id = ? ORDER BY occurred_at, recorded_at
    `).all(String(incident.id)),
  }));
  return { query: assertText(query, "query", 200), incidents };
}

export function getSystemContext(db: DatabaseSync, systemId: string): JsonObject {
  const system = db.prepare("SELECT * FROM systems WHERE id = ?").get(systemId);
  if (!system) throw new Error(`Unknown system_id: ${systemId}`);
  const now = nowIso();
  return {
    system,
    interfaces: db.prepare("SELECT * FROM interfaces WHERE system_id = ? ORDER BY purpose").all(systemId),
    services: db.prepare("SELECT * FROM services WHERE system_id = ? ORDER BY name").all(systemId),
    access_profiles: db.prepare("SELECT * FROM access_profiles WHERE system_id = ? ORDER BY method").all(systemId),
    capabilities: db.prepare("SELECT * FROM capabilities WHERE system_id = ? ORDER BY name").all(systemId),
    facts: db.prepare("SELECT * FROM facts WHERE system_id = ? AND status = 'active' ORDER BY category, fact_key").all(systemId),
    current_observations: db.prepare(`
      SELECT o.*
      FROM observations o
      JOIN (
        SELECT kind, MAX(observed_at) AS latest
        FROM observations
        WHERE system_id = ? AND valid_until > ?
        GROUP BY kind
      ) latest ON o.kind = latest.kind AND o.observed_at = latest.latest
      WHERE o.system_id = ? AND o.valid_until > ?
      ORDER BY o.observed_at DESC
      LIMIT 30
    `).all(systemId, now, systemId, now),
    dependencies: db.prepare("SELECT * FROM dependencies WHERE from_system_id = ? OR to_system_id = ? ORDER BY relationship").all(systemId, systemId),
    maintenance: db.prepare("SELECT * FROM maintenance WHERE system_id = ? AND status != 'completed' ORDER BY due_at").all(systemId),
    incidents: db.prepare("SELECT * FROM incidents WHERE system_id = ? ORDER BY updated_at DESC LIMIT 30").all(systemId),
    incident_events: db.prepare(`
      SELECT ie.* FROM incident_events ie
      JOIN incidents i ON i.id = ie.incident_id
      WHERE i.system_id = ? ORDER BY ie.occurred_at DESC LIMIT 100
    `).all(systemId),
    decisions: db.prepare("SELECT * FROM decisions WHERE system_id = ? ORDER BY decided_at DESC LIMIT 30").all(systemId),
    recent_changes: db.prepare("SELECT * FROM changes WHERE system_id = ? ORDER BY occurred_at DESC LIMIT 20").all(systemId),
  };
}

export function getSystemContextBatch(db: DatabaseSync, systemIds: string[]): JsonObject {
  const uniqueIds = [...new Set(systemIds.map((value) => assertText(value, "system_id", 120)))];
  if (uniqueIds.length < 1 || uniqueIds.length > 8) throw new Error("system_ids must contain between 1 and 8 unique identifiers");
  return {
    generated_at: nowIso(),
    systems: uniqueIds.map((systemId) => getSystemContext(db, systemId)),
    freshness: freshnessSummary(db),
  };
}

export function proposeLearningCandidate(db: DatabaseSync, input: LearningCandidateInput): JsonObject {
  ensureSystem(db, input.system_id);
  const id = input.id ? assertText(input.id, "id", 120) : randomUUID();
  const existing = db.prepare("SELECT status FROM learning_candidates WHERE id = ?").get(id) as { status?: string } | undefined;
  if (existing && existing.status !== "proposed") throw new Error("Only a proposed learning candidate may be replaced");
  const timestamp = nowIso();
  const reviewDueAt = addHours(timestamp, 14 * 24) as string;
  db.prepare(`
    INSERT INTO learning_candidates(
      id, system_id, candidate_type, title, trigger, proposed_change, evidence,
      validation_plan, status, source, review_due_at, created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'proposed', ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      system_id = excluded.system_id, candidate_type = excluded.candidate_type,
      title = excluded.title, trigger = excluded.trigger,
      proposed_change = excluded.proposed_change, evidence = excluded.evidence,
      validation_plan = excluded.validation_plan, source = excluded.source,
      review_due_at = excluded.review_due_at,
      updated_at = excluded.updated_at
  `).run(
    id, input.system_id ?? null, input.candidate_type,
    assertText(input.title, "title", 500), assertText(input.trigger, "trigger", 4000),
    assertText(input.proposed_change, "proposed_change"), assertText(input.evidence, "evidence"),
    assertText(input.validation_plan, "validation_plan"), assertText(input.source, "source", 500),
    reviewDueAt, timestamp, timestamp,
  );
  return { ok: true, id, status: "proposed", review_due_at: reviewDueAt };
}

function learningCandidateWithDeadline(row: Record<string, unknown>, reference = new Date()): JsonObject {
  const reviewDueAt = row.review_due_at ? new Date(String(row.review_due_at)) : null;
  const active = ["proposed", "approved"].includes(String(row.status));
  const remainingMilliseconds = reviewDueAt && !Number.isNaN(reviewDueAt.getTime())
    ? reviewDueAt.getTime() - reference.getTime()
    : null;
  return {
    ...row,
    overdue: Boolean(active && remainingMilliseconds !== null && remainingMilliseconds < 0),
    days_remaining: remainingMilliseconds === null ? null : Math.ceil(remainingMilliseconds / 86_400_000),
  };
}

export function listLearningCandidates(db: DatabaseSync, statuses: string[] = ["proposed", "approved"]): JsonObject {
  const allowed = new Set(["proposed", "approved", "rejected", "applied"]);
  const uniqueStatuses = [...new Set(statuses)];
  if (uniqueStatuses.length < 1 || uniqueStatuses.length > 4 || uniqueStatuses.some((value) => !allowed.has(value))) {
    throw new Error("statuses are invalid");
  }
  const placeholders = uniqueStatuses.map(() => "?").join(", ");
  return {
    candidates: db.prepare(`
      SELECT * FROM learning_candidates WHERE status IN (${placeholders})
      ORDER BY CASE status WHEN 'proposed' THEN 0 WHEN 'approved' THEN 1 ELSE 2 END,
               updated_at DESC
    `).all(...uniqueStatuses).map((row) => learningCandidateWithDeadline(row as Record<string, unknown>)),
  };
}

export function reviewLearningCandidate(db: DatabaseSync, input: LearningCandidateReviewInput): JsonObject {
  const id = assertText(input.id, "id", 120);
  const existing = db.prepare("SELECT * FROM learning_candidates WHERE id = ?").get(id) as Record<string, unknown> | undefined;
  if (!existing) throw new Error("Unknown learning candidate");
  if (["rejected", "applied"].includes(String(existing.status))) throw new Error("The learning candidate is already terminal");
  const nextStatus = input.action === "approve" ? "approved" : input.action === "reject" ? "rejected" : "applied";
  if (nextStatus === "applied" && existing.status !== "approved") throw new Error("A learning candidate must be approved before it can be applied");
  const appliedChangeId = input.applied_change_id ? assertText(input.applied_change_id, "applied_change_id", 120) : null;
  if (nextStatus === "applied") {
    if (!appliedChangeId) throw new Error("applied_change_id is required when applying a learning candidate");
    const change = db.prepare("SELECT result FROM changes WHERE id = ?").get(appliedChangeId) as { result?: string } | undefined;
    if (!change || change.result !== "succeeded") throw new Error("applied_change_id must reference a succeeded change");
  }
  const timestamp = nowIso();
  db.prepare(`
    UPDATE learning_candidates SET status=?, reviewed_at=?, review_reference=?,
      validation=?, applied_change_id=?, updated_at=? WHERE id=?
  `).run(
    nextStatus, timestamp, assertText(input.review_reference, "review_reference", 1000),
    assertText(input.validation, "validation"), appliedChangeId, timestamp, id,
  );
  return { ok: true, id, status: nextStatus };
}

export function createTaskContract(db: DatabaseSync, input: TaskContractCreateInput, boundThreadId: string): JsonObject {
  const targetThreadId = assertThreadId(boundThreadId);
  const criteria = [...new Set(input.success_criteria.map((value) => assertText(value, "success_criterion", 2000)))];
  if (criteria.length < 1 || criteria.length > 20) throw new Error("success_criteria must contain between 1 and 20 entries");
  const existing = db.prepare(`
    SELECT id FROM task_contracts
    WHERE target_thread_id = ? AND status IN ('active', 'waiting', 'blocked')
  `).get(targetThreadId);
  if (existing) throw new Error("This Codex task already has an open completion contract");
  const id = input.id ? assertText(input.id, "id", 120) : randomUUID();
  const timestamp = nowIso();
  const objective = assertText(input.objective, "objective", 4000);
  const source = assertText(input.source, "source", 500);
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(`
      INSERT INTO task_contracts(
        id, target_thread_id, objective, success_criteria_json, status,
        current_step, source, created_at, updated_at
      ) VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?)
    `).run(id, targetThreadId, objective, JSON.stringify(criteria), optionalText(input.current_step, "current_step", 2000), source, timestamp, timestamp);
    db.prepare(`
      INSERT INTO task_contract_events(id, contract_id, event_type, from_status,
        to_status, summary, source, occurred_at)
      VALUES (?, ?, 'created', NULL, 'active', ?, ?, ?)
    `).run(randomUUID(), id, objective, source, timestamp);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return { ok: true, id, status: "active" };
}

export function updateTaskContract(db: DatabaseSync, input: TaskContractUpdateInput, boundThreadId?: string | null): JsonObject {
  const id = assertText(input.id, "id", 120);
  const existing = db.prepare("SELECT * FROM task_contracts WHERE id = ?").get(id) as Record<string, unknown> | undefined;
  if (!existing) throw new Error("Unknown completion contract");
  if (boundThreadId && String(existing.target_thread_id) !== assertThreadId(boundThreadId)) {
    throw new Error("The completion contract belongs to a different Codex task");
  }
  const currentStatus = String(existing.status);
  if (["completed", "cancelled"].includes(currentStatus)) throw new Error("The completion contract is already terminal");
  const allowedTransitions: Record<string, Set<string>> = {
    active: new Set(["active", "waiting", "blocked", "completed", "cancelled"]),
    waiting: new Set(["active", "waiting", "blocked", "completed", "cancelled"]),
    blocked: new Set(["active", "waiting", "blocked", "completed", "cancelled"]),
  };
  if (!allowedTransitions[currentStatus]?.has(input.status)) throw new Error("Invalid completion-contract status transition");
  const waitReason = optionalText(input.wait_reason, "wait_reason", 4000);
  const waitJobId = optionalText(input.wait_job_id, "wait_job_id", 120);
  const verification = optionalText(input.verification, "verification");
  if (["waiting", "blocked"].includes(input.status) && !waitReason) throw new Error("wait_reason is required for waiting or blocked contracts");
  if (input.status === "completed" && !verification) throw new Error("verification is required before completing a contract");
  const timestamp = nowIso();
  const source = assertText(input.source, "source", 500);
  const eventType = input.status === "completed" ? "completed"
    : input.status === "cancelled" ? "cancelled"
      : input.status === "waiting" ? "waiting"
        : input.status === "blocked" ? "blocked"
          : currentStatus === "waiting" || currentStatus === "blocked" ? "resumed" : "progressed";
  const summary = input.status === "completed" ? verification as string
    : optionalText(input.current_step, "current_step", 2000) ?? waitReason ?? `Status changed to ${input.status}`;
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(`
      UPDATE task_contracts SET status=?, current_step=?, wait_reason=?, wait_job_id=?,
        verification=?, updated_at=?, completed_at=? WHERE id=?
    `).run(
      input.status, optionalText(input.current_step, "current_step", 2000),
      ["waiting", "blocked"].includes(input.status) ? waitReason : null,
      input.status === "waiting" ? waitJobId : null, verification, timestamp,
      input.status === "completed" ? timestamp : null, id,
    );
    db.prepare(`
      INSERT INTO task_contract_events(id, contract_id, event_type, from_status,
        to_status, summary, source, occurred_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(randomUUID(), id, eventType, currentStatus, input.status, summary, source, timestamp);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return { ok: true, id, status: input.status };
}

export function getTaskContracts(db: DatabaseSync, targetThreadId?: string | null, includeFinished = false): JsonObject {
  const parameters: Array<string | number> = [];
  const clauses: string[] = [];
  if (targetThreadId) {
    clauses.push("target_thread_id = ?");
    parameters.push(assertThreadId(targetThreadId));
  }
  if (!includeFinished) clauses.push("status IN ('active', 'waiting', 'blocked')");
  const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
  const rows = db.prepare(`SELECT * FROM task_contracts ${where} ORDER BY updated_at DESC`).all(...parameters);
  return {
    contracts: rows.map((row) => {
      const item = row as Record<string, unknown>;
      const id = String(item.id);
      return {
        ...publicTaskContract(item),
        events: db.prepare("SELECT * FROM task_contract_events WHERE contract_id = ? ORDER BY occurred_at").all(id),
      };
    }),
  };
}

export function recordFact(db: DatabaseSync, input: FactInput): JsonObject {
  ensureSystem(db, input.system_id);
  const observedAt = input.observed_at ? new Date(input.observed_at).toISOString() : nowIso();
  const systemId = input.system_id ?? null;
  const category = assertText(input.category, "category", 80);
  const factKey = assertText(input.fact_key, "fact_key", 120);
  const factValue = assertText(input.fact_value, "fact_value");
  const source = assertText(input.source, "source", 500);
  if (input.confidence < 0 || input.confidence > 1) throw new Error("confidence must be between 0 and 1");
  const previous = db.prepare(`
    SELECT id FROM facts WHERE system_id IS ? AND fact_key = ? AND status = 'active'
    ORDER BY updated_at DESC LIMIT 1
  `).get(systemId, factKey) as { id?: string } | undefined;
  const id = randomUUID();
  db.exec("BEGIN IMMEDIATE");
  try {
    if (previous?.id) db.prepare("UPDATE facts SET status = 'superseded', updated_at = ? WHERE id = ?").run(nowIso(), previous.id);
    db.prepare(`
      INSERT INTO facts(
        id, system_id, category, fact_key, fact_value, source, observed_at,
        last_verified_at, valid_until, confidence, status, supersedes_id, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
    `).run(
      id, systemId, category, factKey, factValue, source, observedAt, observedAt,
      addHours(observedAt, input.valid_for_hours), input.confidence, previous?.id ?? null, nowIso(),
    );
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return { ok: true, id, superseded_id: previous?.id ?? null };
}

export function recordObservation(db: DatabaseSync, input: ObservationInput): JsonObject {
  ensureSystem(db, input.system_id);
  const observedAt = input.observed_at ? new Date(input.observed_at).toISOString() : nowIso();
  if (input.confidence < 0 || input.confidence > 1) throw new Error("confidence must be between 0 and 1");
  if (input.valid_for_hours < 1 || input.valid_for_hours > 8760) throw new Error("valid_for_hours is out of range");
  const id = randomUUID();
  db.prepare(`
    INSERT INTO observations(
      id, system_id, kind, status, summary, details, source,
      observed_at, valid_until, confidence, recorded_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    id, input.system_id ?? null, assertText(input.kind, "kind", 100), input.status,
    assertText(input.summary, "summary", 500), optionalText(input.details, "details"),
    assertText(input.source, "source", 500), observedAt, addHours(observedAt, input.valid_for_hours),
    input.confidence, nowIso(),
  );
  return { ok: true, id };
}

export function recordAccessTest(db: DatabaseSync, input: AccessTestInput): JsonObject {
  const profileId = assertText(input.profile_id, "profile_id", 120);
  const profile = db.prepare(`
    SELECT id, system_id, identity, method FROM access_profiles WHERE id = ?
  `).get(profileId) as { id: string; system_id: string; identity: string; method: string } | undefined;
  if (!profile) throw new Error(`Unknown access profile: ${profileId}`);
  const testedAt = input.tested_at ? new Date(input.tested_at).toISOString() : nowIso();
  const evidence = assertText(input.evidence, "evidence", 4000);
  const source = assertText(input.source, "source", 500);
  const validForHours = input.valid_for_hours ?? 168;
  if (!Number.isInteger(validForHours) || validForHours < 1 || validForHours > 8760) {
    throw new Error("valid_for_hours is out of range");
  }
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(`
      UPDATE access_profiles SET last_tested_at = ?, test_result = ?, updated_at = ? WHERE id = ?
    `).run(testedAt, input.result, nowIso(), profileId);
    db.prepare(`
      UPDATE capabilities
      SET last_tested_at = ?, test_result = ?, evidence = ?, updated_at = ?
      WHERE access_profile_id = ?
    `).run(testedAt, input.result, evidence, nowIso(), profileId);
    const observationId = randomUUID();
    db.prepare(`
      INSERT INTO observations(
        id, system_id, kind, status, summary, details, source,
        observed_at, valid_until, confidence, recorded_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
    `).run(
      observationId, profile.system_id, `access_test:${profileId}`,
      input.result === "verified" ? "ok" : "critical",
      `${profile.identity} via ${profile.method}: ${input.result}`,
      evidence, source, testedAt, addHours(testedAt, validForHours), nowIso(),
    );
    db.exec("COMMIT");
    return { ok: true, profile_id: profileId, observation_id: observationId, result: input.result };
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

export function recordChange(db: DatabaseSync, input: ChangeInput): JsonObject {
  ensureSystem(db, input.system_id);
  const id = randomUUID();
  const occurredAt = input.occurred_at ? new Date(input.occurred_at).toISOString() : nowIso();
  db.prepare(`
    INSERT INTO changes(
      id, system_id, requested_by, approval_reference, summary, before_state,
      after_state, verification, rollback, result, occurred_at, recorded_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    id, input.system_id ?? null, assertText(input.requested_by ?? "user", "requested_by", 100),
    optionalText(input.approval_reference, "approval_reference", 500),
    assertText(input.summary, "summary", 1000), optionalText(input.before_state, "before_state"),
    optionalText(input.after_state, "after_state"), assertText(input.verification, "verification"),
    assertText(input.rollback, "rollback"), input.result, occurredAt, nowIso(),
  );
  return { ok: true, id };
}

export function recordIncident(db: DatabaseSync, input: IncidentInput): JsonObject {
  ensureSystem(db, input.system_id);
  const occurredAt = input.occurred_at ? new Date(input.occurred_at).toISOString() : nowIso();
  const requestedId = input.id ? assertText(input.id, "id", 120) : null;
  const existing = requestedId ? db.prepare("SELECT * FROM incidents WHERE id = ?").get(requestedId) as Record<string, unknown> | undefined : undefined;
  if (requestedId && !existing) throw new Error(`Unknown incident id: ${requestedId}`);
  const id = requestedId ?? randomUUID();
  const title = assertText(input.title, "title", 500);
  const symptoms = assertText(input.symptoms, "symptoms");
  const rootCause = optionalText(input.root_cause, "root_cause");
  const remediation = optionalText(input.remediation, "remediation");
  const prevention = optionalText(input.prevention, "prevention");
  const source = assertText(input.source, "source", 500);
  const previousStatus = existing ? String(existing.status) : null;
  const eventType = !existing ? "opened"
    : previousStatus === "resolved" && input.status !== "resolved" ? "reopened"
      : previousStatus !== input.status && input.status === "resolved" ? "resolved"
        : previousStatus !== input.status ? "status_changed" : "updated";
  const openedAt = existing ? String(existing.opened_at) : occurredAt;
  const resolvedAt = input.status === "resolved" ? occurredAt : null;
  const eventSummary = optionalText(input.event_summary, "event_summary", 1000)
    ?? `${eventType}: ${title}`;
  const eventDetails = optionalText(input.event_details, "event_details");
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(`
      INSERT INTO incidents(
        id, system_id, title, severity, status, symptoms, root_cause, remediation,
        prevention, opened_at, resolved_at, source, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        system_id = excluded.system_id, title = excluded.title, severity = excluded.severity,
        status = excluded.status, symptoms = excluded.symptoms, root_cause = excluded.root_cause,
        remediation = excluded.remediation, prevention = excluded.prevention,
        resolved_at = excluded.resolved_at, source = excluded.source, updated_at = excluded.updated_at
    `).run(
      id, input.system_id ?? null, title, input.severity, input.status, symptoms,
      rootCause, remediation, prevention, openedAt, resolvedAt, source, occurredAt,
    );
    const eventId = randomUUID();
    db.prepare(`
      INSERT INTO incident_events(
        id, incident_id, event_type, from_status, to_status, summary, details,
        source, occurred_at, recorded_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(eventId, id, eventType, previousStatus, input.status, eventSummary, eventDetails, source, occurredAt, nowIso());
    db.exec("COMMIT");
    return { ok: true, id, event_id: eventId, event_type: eventType, status: input.status };
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

export function recordDecision(db: DatabaseSync, input: DecisionInput): JsonObject {
  ensureSystem(db, input.system_id);
  const id = input.id ? assertText(input.id, "id", 120) : randomUUID();
  const decidedAt = input.decided_at ? new Date(input.decided_at).toISOString() : nowIso();
  db.prepare(`
    INSERT INTO decisions(
      id, title, context, decision, rationale, alternatives, status,
      decided_at, source, updated_at, system_id
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      title = excluded.title, context = excluded.context, decision = excluded.decision,
      rationale = excluded.rationale, alternatives = excluded.alternatives,
      status = excluded.status, decided_at = excluded.decided_at,
      source = excluded.source, updated_at = excluded.updated_at,
      system_id = excluded.system_id
  `).run(
    id, assertText(input.title, "title", 500), assertText(input.context, "context"),
    assertText(input.decision, "decision"), assertText(input.rationale, "rationale"),
    optionalText(input.alternatives, "alternatives"), input.status, decidedAt,
    assertText(input.source, "source", 500), nowIso(), input.system_id ?? null,
  );
  return { ok: true, id, status: input.status };
}

export function upsertMaintenance(db: DatabaseSync, input: MaintenanceInput): JsonObject {
  ensureSystem(db, input.system_id);
  const id = assertText(input.id, "id", 120);
  db.prepare(`
    INSERT INTO maintenance(
      id, system_id, category, title, status, due_at, interval_days,
      verification, notes, source, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      system_id = excluded.system_id, category = excluded.category, title = excluded.title,
      status = excluded.status, due_at = excluded.due_at, interval_days = excluded.interval_days,
      verification = excluded.verification, notes = excluded.notes,
      source = excluded.source, updated_at = excluded.updated_at
  `).run(
    id, input.system_id ?? null, assertText(input.category, "category", 80),
    assertText(input.title, "title", 500), input.status, input.due_at ?? null,
    input.interval_days ?? null, optionalText(input.verification, "verification"),
    optionalText(input.notes, "notes"), assertText(input.source, "source", 500), nowIso(),
  );
  return { ok: true, id };
}

export function integrityReport(db: DatabaseSync): JsonObject {
  const integrity = db.prepare("PRAGMA integrity_check").all();
  const foreignKeys = db.prepare("PRAGMA foreign_key_check").all();
  return {
    ok: integrity.length === 1 && (integrity[0] as { integrity_check?: string }).integrity_check === "ok" && foreignKeys.length === 0,
    integrity,
    foreign_key_violations: foreignKeys,
    statistics: databaseStatistics(db),
  };
}
