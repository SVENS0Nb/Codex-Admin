import { readFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import net from "node:net";
import tls from "node:tls";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/server";
import { serveStdio } from "@modelcontextprotocol/server/stdio";
import * as z from "zod/v4";
import { contextBootstrap, createTaskContract, databaseStatistics, freshnessReport, getSystemContext, getSystemContextBatch, getTaskContracts, listLearningCandidates, openKnowledgeDatabase, proposeLearningCandidate, recordAccessTest, recordChange, recordDecision, recordFact, recordIncident, recordObservation, reviewLearningCandidate, searchIncidents, searchKnowledge, synchronizeKnowledgeBase, updateTaskContract, upsertMaintenance, } from "./database.js";
const currentDir = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(currentDir, "..", "..", "..");
const inventoryPath = path.join(repositoryRoot, "inventory", "services.json");
const policyPath = path.join(repositoryRoot, "config", "admin-policy.json");
const serviceNames = ["proxmox", "home_assistant", "reverse_proxy", "unifi"];
const execFileAsync = promisify(execFile);
async function readJson(filePath) {
    return JSON.parse(await readFile(filePath, "utf8"));
}
function textResult(value) {
    return {
        content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
    };
}
function boundCodexThreadId() {
    const value = String(process.env.CODEX_THREAD_ID ?? "").trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
        throw new Error("CODEX_THREAD_ID is unavailable or invalid; task contracts are disabled for this MCP process");
    }
    return value;
}
async function getService(name) {
    const inventory = await readJson(inventoryPath);
    const service = inventory.services[name];
    if (!service.enabled || !service.base_url) {
        throw new Error(`${name} is not enabled and configured in inventory/services.json`);
    }
    return service;
}
function checkTcp(host, port, timeoutMs) {
    return new Promise((resolve) => {
        const started = Date.now();
        const socket = net.createConnection({ host, port });
        let settled = false;
        const finish = (result) => {
            if (settled)
                return;
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
function normalizeFingerprint(value) {
    return value ? value.replaceAll(":", "").toUpperCase() : null;
}
function inspectNodeTls(host, port, servername, expectedFingerprint, timeoutMs) {
    return new Promise((resolve, reject) => {
        const socket = tls.connect({ host, port, servername, rejectUnauthorized: false });
        socket.setTimeout(timeoutMs);
        socket.once("secureConnect", () => {
            const cert = socket.getPeerCertificate();
            const actualFingerprint = normalizeFingerprint(cert.fingerprint256);
            const pinnedFingerprint = normalizeFingerprint(expectedFingerprint);
            const result = {
                trusted_by_node: socket.authorized,
                node_authorization_error: socket.authorizationError ?? null,
                pinned_fingerprint_matches: pinnedFingerprint ? actualFingerprint === pinnedFingerprint : null,
                protocol: socket.getProtocol(),
                subject: cert.subject ?? null,
                issuer: cert.issuer ?? null,
                valid_from: cert.valid_from ?? null,
                valid_to: cert.valid_to ?? null,
                fingerprint_sha256: actualFingerprint,
            };
            socket.end();
            resolve(result);
        });
        socket.once("timeout", () => {
            socket.destroy();
            reject(new Error("TLS connection timed out"));
        });
        socket.once("error", reject);
    });
}
async function inspectWindowsTrust(host, port, servername, timeoutMs) {
    if (process.platform !== "win32") {
        return {
            trusted_by_windows: null,
            windows_authorization_error: "Windows Schannel verification is unavailable on this platform",
        };
    }
    const script = String.raw `
$ErrorActionPreference = 'Stop'
$client = [Net.Sockets.TcpClient]::new()
$ssl = $null
try {
    $timeout = [int]$env:HOMELAB_TLS_TIMEOUT_MS
    $connect = $client.ConnectAsync($env:HOMELAB_TLS_HOST, [int]$env:HOMELAB_TLS_PORT)
    if (-not $connect.Wait($timeout)) { throw 'TCP connection timed out' }
    $ssl = [Net.Security.SslStream]::new($client.GetStream(), $false)
    $ssl.ReadTimeout = $timeout
    $ssl.WriteTimeout = $timeout
    $ssl.AuthenticateAsClient($env:HOMELAB_TLS_SERVERNAME)
    [pscustomobject]@{
        trusted = $ssl.IsAuthenticated
        protocol = [string]$ssl.SslProtocol
    } | ConvertTo-Json -Compress
}
finally {
    if ($ssl) { $ssl.Dispose() }
    $client.Dispose()
}`;
    try {
        const { stdout } = await execFileAsync("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], {
            windowsHide: true,
            timeout: timeoutMs + 2000,
            env: {
                ...process.env,
                HOMELAB_TLS_HOST: host,
                HOMELAB_TLS_PORT: String(port),
                HOMELAB_TLS_SERVERNAME: servername,
                HOMELAB_TLS_TIMEOUT_MS: String(timeoutMs),
            },
        });
        const result = JSON.parse(stdout.trim());
        return {
            trusted_by_windows: result.trusted === true,
            windows_authorization_error: null,
            windows_protocol: result.protocol ?? null,
        };
    }
    catch (error) {
        return {
            trusted_by_windows: false,
            windows_authorization_error: error instanceof Error ? error.message : "Windows Schannel verification failed",
            windows_protocol: null,
        };
    }
}
async function inspectTls(host, port, servername, expectedFingerprint, timeoutMs) {
    const [certificate, windowsTrust] = await Promise.all([
        inspectNodeTls(host, port, servername, expectedFingerprint, timeoutMs),
        inspectWindowsTrust(host, port, servername, timeoutMs),
    ]);
    return {
        ...certificate,
        ...windowsTrust,
        authorization_error: windowsTrust.windows_authorization_error ?? null,
    };
}
function createServer() {
    const server = new McpServer({ name: "homelab-admin", version: "0.4.0" });
    const knowledgeDb = openKnowledgeDatabase();
    synchronizeKnowledgeBase(knowledgeDb);
    server.registerTool("access_test_record", {
        description: "Record a verified or failed administrative access test and update the related access profile, capabilities, and expiring observation without storing credential values",
        inputSchema: z.object({
            profile_id: z.string().min(1).max(120),
            result: z.enum(["verified", "failed"]),
            evidence: z.string().min(1).max(4000),
            source: z.string().min(1).max(500),
            valid_for_hours: z.number().int().min(1).max(8760).default(168),
            tested_at: z.string().datetime({ offset: true }).nullable().optional(),
        }),
    }, async (input) => textResult(recordAccessTest(knowledgeDb, input)));
    server.registerTool("context_bootstrap", {
        description: "Load compact authoritative secret-free Homelab orientation at the beginning of every task; use full detail only for whole-environment audits and targeted context tools for individual systems",
        inputSchema: z.object({
            detail: z.enum(["compact", "full"]).default("compact"),
        }),
    }, async ({ detail }) => textResult(contextBootstrap(knowledgeDb, { detail })));
    server.registerTool("knowledge_statistics", {
        description: "Return secret-free Homelab knowledge database counts, schema version, path, and last repository synchronization time",
        inputSchema: z.object({}),
    }, async () => textResult(databaseStatistics(knowledgeDb)));
    server.registerTool("knowledge_freshness_report", {
        description: "List stale facts, stale administrative access tests, and expired observations that require live reverification",
        inputSchema: z.object({}),
    }, async () => textResult(freshnessReport(knowledgeDb)));
    server.registerTool("knowledge_search", {
        description: "Search versioned runbooks, active facts, verified changes, incident solutions, decisions, and maintenance without reading secret values",
        inputSchema: z.object({
            query: z.string().min(1).max(200),
            limit: z.number().int().min(1).max(25).default(10),
        }),
    }, async ({ query, limit }) => textResult(searchKnowledge(knowledgeDb, query, limit)));
    server.registerTool("incident_search", {
        description: "Search diagnosed Homelab problems and reusable resolutions, including their immutable lifecycle events",
        inputSchema: z.object({
            query: z.string().min(1).max(200),
            limit: z.number().int().min(1).max(25).default(10),
        }),
    }, async ({ query, limit }) => textResult(searchIncidents(knowledgeDb, query, limit)));
    server.registerTool("system_context_get", {
        description: "Read all secret-free structured context for one Homelab system, including interfaces, access references, capabilities, facts, observations, dependencies, maintenance, incidents, decisions, and recent changes",
        inputSchema: z.object({
            system_id: z.string().min(1).max(120),
        }),
    }, async ({ system_id }) => textResult(getSystemContext(knowledgeDb, system_id)));
    server.registerTool("system_context_batch_get", {
        description: "Read one bounded secret-free context bundle for up to eight Homelab systems so the agent can correlate dependencies, incidents, observations, decisions, and recent changes without repeated MCP turns",
        inputSchema: z.object({
            system_ids: z.array(z.string().min(1).max(120)).min(1).max(8),
        }),
    }, async ({ system_ids }) => textResult(getSystemContextBatch(knowledgeDb, system_ids)));
    server.registerTool("learning_candidate_propose", {
        description: "Stage a secret-free reusable learning candidate after a complex task or novel incident; this never edits a runbook, skill, policy, automation, or authoritative knowledge source",
        inputSchema: z.object({
            id: z.string().min(1).max(120).nullable().optional(),
            system_id: z.string().min(1).max(120).nullable().optional(),
            candidate_type: z.enum(["runbook", "skill", "automation", "policy", "knowledge"]),
            title: z.string().min(1).max(500),
            trigger: z.string().min(1).max(4000),
            proposed_change: z.string().min(1).max(16384),
            evidence: z.string().min(1).max(16384),
            validation_plan: z.string().min(1).max(16384),
            source: z.string().min(1).max(500),
        }),
    }, async (input) => textResult(proposeLearningCandidate(knowledgeDb, input)));
    server.registerTool("learning_candidate_list", {
        description: "List staged Homelab learning candidates by lifecycle state without applying them",
        inputSchema: z.object({
            statuses: z.array(z.enum(["proposed", "approved", "rejected", "applied"])).min(1).max(4).default(["proposed", "approved"]),
        }),
    }, async ({ statuses }) => textResult(listLearningCandidates(knowledgeDb, statuses)));
    server.registerTool("learning_candidate_review", {
        description: "Approve, reject, or mark a validated learning candidate applied; applying requires a verified succeeded change record and never edits files itself",
        inputSchema: z.object({
            id: z.string().min(1).max(120),
            action: z.enum(["approve", "reject", "apply"]),
            review_reference: z.string().min(1).max(1000),
            validation: z.string().min(1).max(16384),
            applied_change_id: z.string().min(1).max(120).nullable().optional(),
        }),
    }, async (input) => textResult(reviewLearningCandidate(knowledgeDb, input)));
    server.registerTool("task_contract_create", {
        description: "Create one persistent secret-free completion contract for a long-running Homelab task with explicit success criteria",
        inputSchema: z.object({
            id: z.string().min(1).max(120).nullable().optional(),
            objective: z.string().min(1).max(4000),
            success_criteria: z.array(z.string().min(1).max(2000)).min(1).max(20),
            current_step: z.string().max(2000).nullable().optional(),
            source: z.string().min(1).max(500),
        }).strict(),
    }, async (input) => textResult(createTaskContract(knowledgeDb, input, boundCodexThreadId())));
    server.registerTool("task_contract_update", {
        description: "Record progress, waiting, blocking, cancellation, or verified completion in a persistent Homelab task contract and append an immutable lifecycle event",
        inputSchema: z.object({
            id: z.string().min(1).max(120),
            status: z.enum(["active", "waiting", "blocked", "completed", "cancelled"]),
            current_step: z.string().max(2000).nullable().optional(),
            wait_reason: z.string().max(4000).nullable().optional(),
            wait_job_id: z.string().max(120).nullable().optional(),
            verification: z.string().max(16384).nullable().optional(),
            source: z.string().min(1).max(500),
        }),
    }, async (input) => textResult(updateTaskContract(knowledgeDb, input, boundCodexThreadId())));
    server.registerTool("task_contract_get", {
        description: "Read active or historical completion contracts and their immutable events, optionally scoped to the current Codex task",
        inputSchema: z.object({
            include_finished: z.boolean().default(false),
        }).strict(),
    }, async ({ include_finished }) => textResult(getTaskContracts(knowledgeDb, boundCodexThreadId(), include_finished)));
    server.registerTool("incident_record", {
        description: "Create or update a secret-free Homelab incident and append an immutable lifecycle event for reusable diagnosis and remediation knowledge",
        inputSchema: z.object({
            id: z.string().min(1).max(120).nullable().optional(),
            system_id: z.string().min(1).max(120).nullable().optional(),
            title: z.string().min(1).max(500),
            severity: z.enum(["low", "medium", "high", "critical"]),
            status: z.enum(["open", "monitoring", "resolved"]),
            symptoms: z.string().min(1).max(16384),
            root_cause: z.string().max(16384).nullable().optional(),
            remediation: z.string().max(16384).nullable().optional(),
            prevention: z.string().max(16384).nullable().optional(),
            event_summary: z.string().max(1000).nullable().optional(),
            event_details: z.string().max(16384).nullable().optional(),
            source: z.string().min(1).max(500),
            occurred_at: z.string().datetime({ offset: true }).nullable().optional(),
        }),
    }, async (input) => textResult(recordIncident(knowledgeDb, input)));
    server.registerTool("decision_record", {
        description: "Create or update a durable secret-free operational decision with context, rationale, alternatives, and optional system scope",
        inputSchema: z.object({
            id: z.string().min(1).max(120).nullable().optional(),
            system_id: z.string().min(1).max(120).nullable().optional(),
            title: z.string().min(1).max(500),
            context: z.string().min(1).max(16384),
            decision: z.string().min(1).max(16384),
            rationale: z.string().min(1).max(16384),
            alternatives: z.string().max(16384).nullable().optional(),
            status: z.enum(["proposed", "active", "superseded"]),
            source: z.string().min(1).max(500),
            decided_at: z.string().datetime({ offset: true }).nullable().optional(),
        }),
    }, async (input) => textResult(recordDecision(knowledgeDb, input)));
    server.registerTool("fact_record", {
        description: "Record a verified stable Homelab fact with provenance, confidence, and optional validity; supersedes rather than destroys conflicting active facts and rejects credential material",
        inputSchema: z.object({
            system_id: z.string().min(1).max(120).nullable().optional(),
            category: z.string().min(1).max(80),
            fact_key: z.string().min(1).max(120),
            fact_value: z.string().min(1).max(16384),
            source: z.string().min(1).max(500),
            confidence: z.number().min(0).max(1),
            valid_for_hours: z.number().int().min(1).max(8760).nullable().optional(),
            observed_at: z.string().datetime({ offset: true }).nullable().optional(),
        }),
    }, async (input) => textResult(recordFact(knowledgeDb, input)));
    server.registerTool("observation_record", {
        description: "Record a time-bound secret-free Homelab check result; use for reachability, health, version, certificate, backup, or access-test observations",
        inputSchema: z.object({
            system_id: z.string().min(1).max(120).nullable().optional(),
            kind: z.string().min(1).max(100),
            status: z.enum(["ok", "warning", "critical", "unknown"]),
            summary: z.string().min(1).max(500),
            details: z.string().max(16384).nullable().optional(),
            source: z.string().min(1).max(500),
            confidence: z.number().min(0).max(1),
            valid_for_hours: z.number().int().min(1).max(8760),
            observed_at: z.string().datetime({ offset: true }).nullable().optional(),
        }),
    }, async (input) => textResult(recordObservation(knowledgeDb, input)));
    server.registerTool("change_record", {
        description: "Record a completed or rolled-back Homelab change with before/after state, verification, rollback, result, and approval reference; rejects credential material",
        inputSchema: z.object({
            system_id: z.string().min(1).max(120).nullable().optional(),
            requested_by: z.string().min(1).max(100).default("user"),
            approval_reference: z.string().max(500).nullable().optional(),
            summary: z.string().min(1).max(1000),
            before_state: z.string().max(16384).nullable().optional(),
            after_state: z.string().max(16384).nullable().optional(),
            verification: z.string().min(1).max(16384),
            rollback: z.string().min(1).max(16384),
            result: z.enum(["succeeded", "failed", "rolled_back", "partial"]),
            occurred_at: z.string().datetime({ offset: true }).nullable().optional(),
        }),
    }, async (input) => textResult(recordChange(knowledgeDb, input)));
    server.registerTool("maintenance_upsert", {
        description: "Create or update a secret-free Homelab maintenance item with due date, recurrence, verification criteria, and status",
        inputSchema: z.object({
            id: z.string().min(1).max(120),
            system_id: z.string().min(1).max(120).nullable().optional(),
            category: z.string().min(1).max(80),
            title: z.string().min(1).max(500),
            status: z.enum(["open", "scheduled", "completed", "deferred"]),
            due_at: z.string().datetime({ offset: true }).nullable().optional(),
            interval_days: z.number().int().min(1).max(3650).nullable().optional(),
            verification: z.string().max(16384).nullable().optional(),
            notes: z.string().max(16384).nullable().optional(),
            source: z.string().min(1).max(500),
        }),
    }, async (input) => textResult(upsertMaintenance(knowledgeDb, input)));
    server.registerTool("inventory_get", {
        description: "Read the non-secret homelab service inventory and workstation metadata",
        inputSchema: z.object({}),
    }, async () => textResult(await readJson(inventoryPath)));
    server.registerTool("admin_policy_get", {
        description: "Read the local homelab approval and operating policy",
        inputSchema: z.object({}),
    }, async () => textResult(await readJson(policyPath)));
    server.registerTool("service_tcp_check", {
        description: "Check TCP reachability for a configured homelab service without transmitting credentials",
        inputSchema: z.object({
            service: z.enum(serviceNames),
            timeout_ms: z.number().int().min(500).max(15000).default(3000),
        }),
    }, async ({ service, timeout_ms }) => {
        const config = await getService(service);
        const uri = new URL(config.base_url);
        const port = config.tcp_port || Number(uri.port) || (uri.protocol === "https:" ? 443 : 80);
        return textResult({
            service,
            host: uri.hostname,
            port,
            ...(await checkTcp(uri.hostname, port, timeout_ms)),
        });
    });
    server.registerTool("service_read_batch", {
        description: "Perform a bounded parallel secret-free TCP and optional TLS read bundle for configured Homelab services in one MCP turn",
        inputSchema: z.object({
            services: z.array(z.enum(serviceNames)).min(1).max(4),
            include_tls: z.boolean().default(false),
            timeout_ms: z.number().int().min(500).max(15000).default(3000),
        }),
    }, async ({ services, include_tls, timeout_ms }) => {
        const uniqueServices = [...new Set(services)];
        const results = await Promise.all(uniqueServices.map(async (service) => {
            const config = await getService(service);
            const uri = new URL(config.base_url);
            const port = config.tcp_port || Number(uri.port) || (uri.protocol === "https:" ? 443 : 80);
            const tcp = await checkTcp(uri.hostname, port, timeout_ms);
            let tlsResult = null;
            if (include_tls && tcp.reachable && uri.protocol === "https:") {
                tlsResult = await inspectTls(uri.hostname, port, config.detected_common_name || uri.hostname, config.certificate_sha256, timeout_ms);
            }
            return { service, host: uri.hostname, port, tcp, tls: tlsResult };
        }));
        return textResult({ checked_at: new Date().toISOString(), results });
    });
    server.registerTool("service_tls_certificate", {
        description: "Inspect the TLS certificate of a configured HTTPS homelab service",
        inputSchema: z.object({
            service: z.enum(serviceNames),
            timeout_ms: z.number().int().min(500).max(15000).default(5000),
        }),
    }, async ({ service, timeout_ms }) => {
        const config = await getService(service);
        const uri = new URL(config.base_url);
        if (uri.protocol !== "https:")
            throw new Error(`${service} is not configured with HTTPS`);
        const port = config.tcp_port || Number(uri.port) || 443;
        return textResult({
            service,
            host: uri.hostname,
            port,
            ...(await inspectTls(uri.hostname, port, config.detected_common_name || uri.hostname, config.certificate_sha256, timeout_ms)),
        });
    });
    return server;
}
void serveStdio(createServer);
console.error("homelab-admin MCP server listening on stdio");
