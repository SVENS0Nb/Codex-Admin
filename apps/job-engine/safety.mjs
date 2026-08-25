import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const MAX_MANIFEST_ITEMS = 32;
const MAX_DEPENDENCY_ITEMS = 256;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HOST_PATTERN = /^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|\[[0-9A-Fa-f:]+\]|[0-9A-Fa-f:]+)$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/i;
const ROLE_PATTERN = /^[a-z][a-z0-9_-]{0,39}$/;

const HARDLINE_PATTERNS = [
  [/(?:^|\s)(?:pvesh\s+delete|qm\s+(?:destroy|stop)|pct\s+(?:destroy|stop))(?:\s|$)/im, "destructive Proxmox command"],
  [/\b(?:Remove-VM|Remove-VMSnapshot|Remove-VMHardDiskDrive|Clear-Disk|Initialize-Disk|Format-Volume|Remove-StoragePool|Remove-VMSwitch)\b/i, "destructive virtualization or storage command"],
  [/\b(?:New-NetIPAddress|Set-NetIPAddress|Remove-NetIPAddress|New-NetRoute|Set-NetRoute|Remove-NetRoute|Set-DnsClientServerAddress|Disable-NetAdapter)\b/i, "network control-path change"],
  [/(?:^|[;{&|])[ \t]*(?:&[ \t]*)?(?:Restart-Computer|Stop-Computer|shutdown(?:\.exe)?|reboot|poweroff)(?=[ \t\r\n]|$)/im, "host power operation"],
  [/\b(?:Invoke-Expression|iex)\b.*(?:https?:\/\/|\$env:)/i, "dynamic command execution"],
  [/(?:curl|Invoke-WebRequest|irm)\b[^\r\n]*(?:\||;)\s*(?:bash|sh|pwsh|powershell|iex|Invoke-Expression)\b/i, "download-to-execute pipeline"],
];

const READ_ONLY_WRITE_PATTERNS = [
  [/\b(?:Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item|Rename-Item)\b/i, "filesystem mutation in a read-only job"],
  [/\b(?:Start-Process|Start-Job|Register-ScheduledTask|Set-ScheduledTask)\b/i, "detached process or task mutation in a read-only job"],
  [/\bInvoke-RestMethod\b[^\r\n]*\b-Method\s+(?:Post|Put|Patch|Delete)\b/i, "mutating HTTP method in a read-only job"],
];

function cleanText(value, maximumLength = 2048) {
  const text = String(value ?? "").trim();
  if (!text || text.length > maximumLength || text.includes("\0")) throw new Error("Ungültiger Sicherheitsmanifest-Wert.");
  return text;
}

function uniqueArray(values) {
  const source = Array.isArray(values) ? values : [];
  if (source.length > MAX_MANIFEST_ITEMS) throw new Error(`Höchstens ${MAX_MANIFEST_ITEMS} Manifest-Einträge sind erlaubt.`);
  return [...new Set(source)];
}

export function sha256File(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function isWithinRoot(candidate, root) {
  const canonical = (value) => {
    const resolved = path.resolve(value);
    try { return realpathSync.native(resolved); } catch { return resolved; }
  };
  const relative = path.relative(canonical(root), canonical(candidate));
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

export function normalizeSafetyManifest(input = {}, existing = null, allowedRoot = null, commandPath = null) {
  const source = input && typeof input === "object" ? input : {};
  const classification = cleanText(source.safety_classification ?? existing?.safety_classification ?? "manual_only", 40);
  if (!["read_only", "local_state_write", "manual_only"].includes(classification)) {
    throw new Error("Sicherheitsklassifizierung muss read_only, local_state_write oder manual_only sein.");
  }
  const requiredCredentialRefs = uniqueArray(source.required_credential_refs ?? existing?.required_credential_refs ?? []).map((value) => {
    const id = cleanText(value, 80);
    if (!UUID_PATTERN.test(id)) throw new Error("Credential-Referenzen müssen DPAPI-Datensatz-UUIDs sein.");
    return id;
  });
  const requiredEndpoints = uniqueArray(source.required_endpoints ?? existing?.required_endpoints ?? []).map((value) => {
    const item = value && typeof value === "object" ? value : {};
    const host = cleanText(item.host, 255);
    const port = Number(item.port);
    if (!HOST_PATTERN.test(host) || !Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error("Erforderliche Endpunkte benötigen einen gültigen Host und TCP-Port.");
    }
    return { host, port };
  });
  const expectedArtifacts = uniqueArray(source.expected_artifacts ?? existing?.expected_artifacts ?? []).map((value) => {
    const template = cleanText(value, 2048);
    const placeholders = template.match(/\{[^}]+\}/g) || [];
    if (placeholders.some((placeholder) => placeholder !== "{yyyy-MM-dd}")) {
      throw new Error("Erwartete Artefakte unterstützen nur den Platzhalter {yyyy-MM-dd}.");
    }
    if (!path.isAbsolute(template)) throw new Error("Erwartete Artefakte benötigen absolute Pfade.");
    const resolved = path.resolve(template);
    return resolved;
  });
  const dependencySource = source.dependency_manifest ?? existing?.dependency_manifest ?? [];
  if (!Array.isArray(dependencySource) || dependencySource.length > MAX_DEPENDENCY_ITEMS) {
    throw new Error(`Höchstens ${MAX_DEPENDENCY_ITEMS} Dateiabhängigkeiten sind erlaubt.`);
  }
  const seenDependencies = new Set();
  const dependencyManifest = dependencySource.map((value) => {
    const item = value && typeof value === "object" ? value : {};
    const dependencyPath = path.resolve(cleanText(item.path, 2048));
    const sha256 = cleanText(item.sha256, 64).toLowerCase();
    const role = cleanText(item.role ?? "runtime_dependency", 40).toLowerCase();
    if (!path.isAbsolute(dependencyPath) || !SHA256_PATTERN.test(sha256) || !ROLE_PATTERN.test(role)) {
      throw new Error("Dateiabhängigkeiten benötigen absoluten Pfad, SHA-256 und eine gültige Rolle.");
    }
    const isExactCommand = commandPath &&
      (process.platform === "win32" ? dependencyPath.toLowerCase() === path.resolve(commandPath).toLowerCase() : dependencyPath === path.resolve(commandPath)) &&
      role === "command";
    if (allowedRoot && !isWithinRoot(dependencyPath, allowedRoot) && !isExactCommand) {
      throw new Error("Dateiabhängigkeiten müssen innerhalb des Job-Arbeitsverzeichnisses liegen.");
    }
    const identity = process.platform === "win32" ? dependencyPath.toLowerCase() : dependencyPath;
    if (seenDependencies.has(identity)) throw new Error("Dateiabhängigkeiten dürfen nicht doppelt vorkommen.");
    seenDependencies.add(identity);
    return { path: dependencyPath, sha256, role };
  });
  return {
    safety_classification: classification,
    required_credential_refs: requiredCredentialRefs,
    required_endpoints: requiredEndpoints,
    expected_artifacts: expectedArtifacts,
    dependency_manifest: dependencyManifest,
  };
}

export function scanCommandSafety(commandPath, commandType, classification) {
  if (commandType !== "powershell") return { ok: true, findings: ["Executable content is opaque; the exact file hash is pinned."] };
  const content = readFileSync(commandPath, "utf8");
  const patterns = classification === "read_only" ? [...HARDLINE_PATTERNS, ...READ_ONLY_WRITE_PATTERNS] : HARDLINE_PATTERNS;
  const findings = patterns.filter(([pattern]) => pattern.test(content)).map(([, label]) => label);
  return { ok: findings.length === 0, findings };
}

function defaultEndpointProbe(endpoints, timeoutMs) {
  if (endpoints.length === 0) return [];
  const script = String.raw`
$ErrorActionPreference = 'Stop'
$items = $env:HOMELAB_PREFLIGHT_ENDPOINTS | ConvertFrom-Json
$timeout = [int]$env:HOMELAB_PREFLIGHT_TIMEOUT_MS
$result = foreach ($item in @($items)) {
  $client = [Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync([string]$item.host, [int]$item.port)
    $reachable = $task.Wait($timeout) -and $client.Connected
    [pscustomobject]@{ host=[string]$item.host; port=[int]$item.port; reachable=$reachable }
  }
  catch {
    [pscustomobject]@{ host=[string]$item.host; port=[int]$item.port; reachable=$false }
  }
  finally { $client.Dispose() }
}
ConvertTo-Json -InputObject @($result) -Compress`;
  const result = spawnSync("pwsh.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], {
    windowsHide: true,
    encoding: "utf8",
    timeout: Math.max(5000, endpoints.length * timeoutMs + 3000),
    env: {
      ...process.env,
      HOMELAB_PREFLIGHT_ENDPOINTS: JSON.stringify(endpoints),
      HOMELAB_PREFLIGHT_TIMEOUT_MS: String(timeoutMs),
    },
  });
  if (result.status !== 0) return endpoints.map((item) => ({ ...item, reachable: false }));
  try {
    const parsed = JSON.parse(result.stdout.trim() || "[]");
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    return endpoints.map((item) => ({ ...item, reachable: false }));
  }
}

export function preflightJob(job, options = {}) {
  const checks = [];
  let commandExists = false;
  let actualHash = null;
  try {
    commandExists = existsSync(job.command_path) && statSync(job.command_path).isFile();
    if (commandExists) actualHash = sha256File(job.command_path);
  } catch {
    commandExists = false;
    actualHash = null;
  }
  checks.push({ check: "command_exists", ok: commandExists });
  const hashMatches = Boolean(actualHash && job.command_sha256 && actualHash === job.command_sha256);
  checks.push({ check: "command_hash", ok: hashMatches });
  let workingDirectoryExists = false;
  try {
    workingDirectoryExists = existsSync(job.working_directory) && statSync(job.working_directory).isDirectory();
  } catch {
    workingDirectoryExists = false;
  }
  checks.push({ check: "working_directory", ok: workingDirectoryExists });
  const dependencyResults = (job.dependency_manifest || []).map((dependency) => {
    const resolved = path.resolve(String(dependency.path || ""));
    const insideRoot = workingDirectoryExists && isWithinRoot(resolved, job.working_directory);
    const normalizedDependency = process.platform === "win32" ? resolved.toLowerCase() : resolved;
    const normalizedCommandPath = process.platform === "win32" ? path.resolve(job.command_path).toLowerCase() : path.resolve(job.command_path);
    const exactCommand = dependency.role === "command" && normalizedDependency === normalizedCommandPath;
    const pathAllowed = insideRoot || exactCommand;
    let exists = false;
    let actualSha256 = null;
    try {
      exists = pathAllowed && existsSync(resolved) && statSync(resolved).isFile();
      if (exists) actualSha256 = sha256File(resolved);
    } catch {
      exists = false;
      actualSha256 = null;
    }
    return {
      path: resolved,
      role: dependency.role,
      inside_root: insideRoot,
      path_allowed: pathAllowed,
      exists,
      hash_matches: Boolean(actualSha256 && actualSha256 === dependency.sha256),
      actual_sha256: actualSha256,
    };
  });
  const commandDependency = dependencyResults.find((dependency) => {
    const left = process.platform === "win32" ? dependency.path.toLowerCase() : dependency.path;
    const right = process.platform === "win32" ? path.resolve(job.command_path).toLowerCase() : path.resolve(job.command_path);
    return left === right && dependency.role === "command";
  });
  checks.push({
    check: "dependency_manifest",
    ok: dependencyResults.length > 0 && Boolean(commandDependency) &&
      dependencyResults.every((item) => item.path_allowed && item.exists && item.hash_matches),
    items: dependencyResults,
  });
  const safety = commandExists ? scanCommandSafety(job.command_path, job.command_type, job.safety_classification) : { ok: false, findings: ["command missing"] };
  checks.push({ check: "command_safety", ok: safety.ok, findings: safety.findings });

  const vaultRoot = path.join(process.env.LOCALAPPDATA || "", "CodexAdmin", "secret-ui");
  const credentialResults = (job.required_credential_refs || []).map((id) => ({
    id,
    available: Boolean(process.env.LOCALAPPDATA) && existsSync(path.join(vaultRoot, `${id}.vault.secret`)),
  }));
  checks.push({ check: "credential_references", ok: credentialResults.every((item) => item.available), items: credentialResults });

  const endpointProbe = options.endpointProbe || defaultEndpointProbe;
  const endpointResults = endpointProbe(job.required_endpoints || [], options.timeoutMs || 2000);
  checks.push({ check: "required_endpoints", ok: endpointResults.every((item) => item.reachable), items: endpointResults });

  const artifactDefinitions = (job.expected_artifacts || []).map((artifactPath) => ({
    path: artifactPath,
    absolute: path.isAbsolute(artifactPath),
  }));
  checks.push({ check: "expected_artifact_definitions", ok: artifactDefinitions.every((item) => item.absolute), items: artifactDefinitions });
  return { ok: checks.every((item) => item.ok), checked_at: new Date().toISOString(), actual_command_sha256: actualHash, checks };
}

function dateInTimezone(timezone, date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone || "Europe/Berlin",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function resolveArtifactTemplate(template, job, now = new Date()) {
  return template.replaceAll("{yyyy-MM-dd}", dateInTimezone(job.timezone, now));
}

export function verifyExpectedArtifacts(job, runStartedAt = null, now = new Date()) {
  const startedMs = runStartedAt ? new Date(runStartedAt).getTime() : null;
  const artifacts = (job.expected_artifacts || []).map((template) => {
    const artifactPath = resolveArtifactTemplate(template, job, now);
    const exists = existsSync(artifactPath);
    let isFile = false;
    let updatedForRun = false;
    if (exists) {
      const stats = statSync(artifactPath);
      isFile = stats.isFile();
      updatedForRun = startedMs === null || Number.isNaN(startedMs) || stats.mtimeMs >= startedMs - 2000;
    }
    return { template, path: artifactPath, exists, is_file: isFile, updated_for_run: updatedForRun };
  });
  return { ok: artifacts.every((item) => item.exists && item.is_file && item.updated_for_run), artifacts };
}

export function parseWakeSignal(value) {
  const lines = String(value || "").trim().split(/\r?\n/).filter(Boolean);
  const candidate = lines.at(-1);
  if (!candidate) return { valid: false, wake_agent: true, context: null, reason: "Kein Wake-Signal vorhanden." };
  try {
    const parsed = JSON.parse(candidate);
    if (typeof parsed?.wakeAgent !== "boolean") throw new Error("wakeAgent fehlt");
    const contextText = parsed.context === undefined || parsed.context === null ? null : JSON.stringify(parsed.context);
    if (contextText && contextText.length > 8000) throw new Error("Wake-Kontext ist zu groß");
    return { valid: true, wake_agent: parsed.wakeAgent, context: parsed.context ?? null, reason: null };
  } catch (error) {
    return { valid: false, wake_agent: true, context: null, reason: `Wake-Signal ungültig: ${error.message}` };
  }
}
