import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { JobEngine, JobStore } from "./engine.mjs";
import { runCodexWake } from "./codex-wake.mjs";

const appRoot = path.dirname(fileURLToPath(import.meta.url));
const publicRoot = path.join(appRoot, "public");
const packageMetadata = JSON.parse(await readFile(path.join(appRoot, "package.json"), "utf8"));
const engineVersion = String(packageMetadata.version || "unknown");
const host = "127.0.0.1";
const port = Number.parseInt(process.env.HOMELAB_JOB_ENGINE_PORT || "8770", 10);
const origin = `http://${host}:${port}`;
const dataRoot = process.env.HOMELAB_JOB_ENGINE_DATA || path.join(process.env.LOCALAPPDATA || os.homedir(), "CodexAdmin", "job-engine");
const databasePath = path.join(dataRoot, "jobs.sqlite3");
const sessionToken = randomBytes(32).toString("base64url");
const csrfToken = randomBytes(32).toString("base64url");
const sessionCookie = "hj_session";
const maxBodyBytes = 262_144;
const testShutdownToken = process.env.HOMELAB_JOB_ENGINE_TEST_SHUTDOWN_TOKEN || "";

if (!Number.isInteger(port) || port < 1024 || port > 65535) {
  throw new Error("HOMELAB_JOB_ENGINE_PORT muss zwischen 1024 und 65535 liegen.");
}

const store = new JobStore(databasePath);
const engine = new JobEngine(store, { wakeRunner: runCodexWake });
engine.start();

function runtimeStatus() {
  const domain = process.env.USERDOMAIN || "";
  const user = process.env.USERNAME || os.userInfo().username;
  return {
    ...engine.status(),
    execution_identity: domain ? `${domain}\\${user}` : user,
  };
}

function safeEqual(left, right) {
  const a = Buffer.from(String(left || ""));
  const b = Buffer.from(String(right || ""));
  return a.length === b.length && timingSafeEqual(a, b);
}

function publicJob(job) {
  if (!job) return null;
  const { wake_thread_id: _threadId, ...safe } = job;
  return { ...safe, wake_thread_bound: Boolean(job.wake_enabled && _threadId) };
}

function parseCookies(header) {
  const result = {};
  for (const item of String(header || "").split(";")) {
    const separator = item.indexOf("=");
    if (separator < 1) continue;
    result[item.slice(0, separator).trim()] = item.slice(separator + 1).trim();
  }
  return result;
}

function securityHeaders(contentType) {
  return {
    "Cache-Control": "no-store, max-age=0",
    "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Content-Type": contentType,
  };
}

function sendJson(response, status, value, extraHeaders = {}) {
  const payload = JSON.stringify(value);
  response.writeHead(status, {
    ...securityHeaders("application/json; charset=utf-8"),
    ...extraHeaders,
    "Content-Length": Buffer.byteLength(payload),
  });
  response.end(payload);
}

function sendText(response, status, value, contentType, extraHeaders = {}) {
  response.writeHead(status, {
    ...securityHeaders(contentType),
    ...extraHeaders,
    "Content-Length": Buffer.byteLength(value),
  });
  response.end(value);
}

function isLoopback(request) {
  return request.socket.remoteAddress === "127.0.0.1" || request.socket.remoteAddress === "::ffff:127.0.0.1";
}

function hasSession(request) {
  return safeEqual(parseCookies(request.headers.cookie)[sessionCookie], sessionToken);
}

function isAuthorizedMutation(request) {
  return hasSession(request) && safeEqual(request.headers.origin, origin) &&
    safeEqual(request.headers["x-csrf-token"], csrfToken) &&
    String(request.headers["content-type"] || "").toLowerCase().startsWith("application/json");
}

async function readJsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBodyBytes) throw new Error("Anfrage ist zu groß.");
    chunks.push(chunk);
  }
  try {
    return chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {};
  } catch {
    throw new Error("Ungültiges JSON.");
  }
}

async function staticAsset(pathname) {
  const assets = {
    "/app.css": ["app.css", "text/css; charset=utf-8"],
    "/app.js": ["app.js", "text/javascript; charset=utf-8"],
  };
  const item = assets[pathname];
  if (!item) return null;
  return { body: await readFile(path.join(publicRoot, item[0]), "utf8"), contentType: item[1] };
}

const indexTemplate = await readFile(path.join(publicRoot, "index.html"), "utf8");

const server = createServer(async (request, response) => {
  try {
    if (!isLoopback(request)) {
      sendJson(response, 403, { error: "Nur lokale Verbindungen sind erlaubt." });
      return;
    }

    const url = new URL(request.url || "/", origin);
    const pathname = url.pathname;

    if (request.method === "GET" && pathname === "/healthz") {
      sendJson(response, 200, { ok: true, service: "homelab-job-engine", version: engineVersion, bind: host, scheduler: runtimeStatus() });
      return;
    }
    if (request.method === "POST" && pathname === "/__test__/shutdown" && testShutdownToken &&
        safeEqual(request.headers["x-test-shutdown-token"], testShutdownToken)) {
      sendJson(response, 200, { ok: true });
      setImmediate(() => shutdown());
      return;
    }
    if (request.method === "GET" && pathname === "/") {
      const page = indexTemplate.replaceAll("__CSRF_TOKEN__", csrfToken);
      sendText(response, 200, page, "text/html; charset=utf-8", {
        "Set-Cookie": `${sessionCookie}=${sessionToken}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800`,
      });
      return;
    }
    if (request.method === "GET" && ["/app.css", "/app.js"].includes(pathname)) {
      const asset = await staticAsset(pathname);
      sendText(response, 200, asset.body, asset.contentType);
      return;
    }
    if (request.method === "GET" && pathname === "/api/state") {
      if (!hasSession(request)) return sendJson(response, 401, { error: "Sitzung fehlt." });
      const runsPage = store.listRunPage(100, url.searchParams.get("runs_offset"));
      sendJson(response, 200, {
        jobs: store.listJobs().map(publicJob),
        one_time_jobs: store.listOneTimeJobs().map(publicJob),
        active_tests: store.listActiveTests().map(publicJob),
        job_names: store.listJobNames(),
        runs: runsPage.items,
        runs_page: {
          total: runsPage.total,
          limit: runsPage.limit,
          offset: runsPage.offset,
          has_previous: runsPage.has_previous,
          has_next: runsPage.has_next,
        },
        engine: runtimeStatus(),
        database: databasePath,
      });
      return;
    }

    const runMatch = pathname.match(/^\/api\/runs\/([0-9a-fA-F-]{36})$/);
    if (request.method === "GET" && runMatch) {
      if (!hasSession(request)) return sendJson(response, 401, { error: "Sitzung fehlt." });
      const details = store.getRunDetails(runMatch[1]);
      if (!details) return sendJson(response, 404, { error: "Ausführung wurde nicht gefunden." });
      sendJson(response, 200, { run: details.run, job: publicJob(details.job) });
      return;
    }

    if (request.method === "POST" && pathname === "/api/jobs") {
      if (!isAuthorizedMutation(request)) return sendJson(response, 403, { error: "Ungültige lokale Sitzung." });
      sendJson(response, 201, store.createJob(await readJsonBody(request)));
      return;
    }

    if (request.method === "POST" && pathname === "/api/one-time-jobs") {
      if (!isAuthorizedMutation(request)) return sendJson(response, 403, { error: "Ungültige lokale Sitzung." });
      const body = await readJsonBody(request);
      sendJson(response, 201, store.createJob({
        ...body,
        job_type: "one_time",
        enabled: true,
        unattended: true,
        auto_archive: true,
      }));
      return;
    }

    if (request.method === "POST" && pathname === "/api/active-tests") {
      if (!isAuthorizedMutation(request)) return sendJson(response, 403, { error: "Ungültige lokale Sitzung." });
      const body = await readJsonBody(request);
      const job = store.createJob({
        ...body,
        job_type: "active_test",
        enabled: false,
        unattended: true,
        auto_archive: true,
      });
      try {
        sendJson(response, 202, { job, run: engine.runActiveTest(job.id) });
      } catch (error) {
        store.deleteJob(job.id);
        throw error;
      }
      return;
    }

    const match = pathname.match(/^\/api\/jobs\/([0-9a-fA-F-]{36})\/(update|delete|run|preflight)$/);
    if (request.method === "POST" && match) {
      if (!isAuthorizedMutation(request)) return sendJson(response, 403, { error: "Ungültige lokale Sitzung." });
      const body = await readJsonBody(request);
      if (match[2] === "update") sendJson(response, 200, store.updateJob(match[1], body));
      else if (match[2] === "delete") {
        if (engine.isJobActive(match[1])) throw new Error("Ein laufender Job kann nicht gelöscht werden.");
        sendJson(response, 200, store.deleteJob(match[1]));
      }
      else if (match[2] === "preflight") sendJson(response, 200, store.runPreflight(match[1]));
      else sendJson(response, 202, engine.runNow(match[1]));
      return;
    }

    sendJson(response, 404, { error: "Nicht gefunden." });
  } catch (error) {
    const message = String(error?.message || "Lokaler Fehler.").slice(0, 1000);
    const status = message.includes("nicht gefunden") ? 404 : message.includes("parallel") || message.includes("läuft bereits") ? 409 : 400;
    sendJson(response, status, { error: message });
  }
});

server.on("error", (error) => {
  console.error(error.code === "EADDRINUSE" ? `Port ${port} wird bereits verwendet.` : `Job-Engine konnte nicht starten: ${error.message}`);
  process.exitCode = 1;
});

server.listen(port, host, () => {
  console.log(`Homelab Job Engine: ${origin}`);
  console.log(`Datenbank: ${databasePath}`);
});

async function shutdown() {
  server.close();
  await engine.stop();
  store.close();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
