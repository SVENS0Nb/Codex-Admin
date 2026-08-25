import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const appRoot = path.dirname(fileURLToPath(import.meta.url));
const publicRoot = path.join(appRoot, "public");
const storeScript = path.join(appRoot, "backend", "SecretUiStore.ps1");
const packageManifest = JSON.parse(await readFile(path.join(appRoot, "package.json"), "utf8"));
const serviceVersion = String(packageManifest.version || "").trim();
const host = "127.0.0.1";
const port = Number.parseInt(process.env.HOMELAB_SECRET_UI_PORT || "8765", 10);
const origin = "http://" + host + ":" + port;
const serviceMode = process.env.HOMELAB_SECRET_UI_SERVICE === "1";
const sessionToken = randomBytes(32).toString("base64url");
const csrfToken = randomBytes(32).toString("base64url");
const sessionCookie = "hs_session";
const maxBodyBytes = 65536;

if (!Number.isInteger(port) || port < 1024 || port > 65535) {
  throw new Error("HOMELAB_SECRET_UI_PORT must be between 1024 and 65535.");
}
if (!/^\d+\.\d+\.\d+$/.test(serviceVersion)) {
  throw new Error("Secret UI package version is invalid.");
}

function safeEqual(left, right) {
  const leftBuffer = Buffer.from(String(left || ""));
  const rightBuffer = Buffer.from(String(right || ""));
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
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

function escapeHtml(value) {
  const entities = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;",
  };
  return String(value).replace(/[&<>"']/g, (character) => entities[character]);
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
  return request.socket.remoteAddress === "127.0.0.1" ||
    request.socket.remoteAddress === "::ffff:127.0.0.1";
}

function hasSession(request) {
  const cookies = parseCookies(request.headers.cookie);
  return safeEqual(cookies[sessionCookie], sessionToken);
}

function isAuthorizedMutation(request) {
  return hasSession(request) &&
    safeEqual(request.headers.origin, origin) &&
    safeEqual(request.headers["x-csrf-token"], csrfToken) &&
    String(request.headers["content-type"] || "").toLowerCase().startsWith("application/json");
}

async function readJsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBodyBytes) {
      throw new Error("REQUEST_TOO_LARGE");
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new Error("INVALID_JSON");
  }
}

function cleanPowerShellError(value) {
  const lines = String(value || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !line.startsWith("At ") && !line.startsWith("+") && !line.includes("CategoryInfo"));
  return lines.at(-1)?.replace(/^.*?:\s*/, "") || "Lokale Geheimnisoperation fehlgeschlagen.";
}

function runStore(action, options = {}) {
  return new Promise((resolve, reject) => {
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
    if (options.clearAfterSeconds) {
      args.push("-ClearAfterSeconds", String(options.clearAfterSeconds));
    }

    const child = spawn("pwsh.exe", args, {
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdout = [];
    const stderr = [];
    let outputBytes = 0;

    child.stdout.on("data", (chunk) => {
      outputBytes += chunk.length;
      if (outputBytes <= 1048576) stdout.push(chunk);
    });
    child.stderr.on("data", (chunk) => {
      outputBytes += chunk.length;
      if (outputBytes <= 1048576) stderr.push(chunk);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(cleanPowerShellError(Buffer.concat(stderr).toString("utf8"))));
        return;
      }
      const text = Buffer.concat(stdout).toString("utf8").trim();
      try {
        resolve(text ? JSON.parse(text) : null);
      } catch {
        reject(new Error("Ungültige Antwort des lokalen DPAPI-Helfers."));
      }
    });

    if (options.input) {
      child.stdin.end(JSON.stringify(options.input));
    } else {
      child.stdin.end();
    }
  });
}

async function getStaticAsset(pathname) {
  const assets = {
    "/app.css": ["app.css", "text/css; charset=utf-8"],
    "/app.js": ["app.js", "text/javascript; charset=utf-8"],
  };
  const entry = assets[pathname];
  if (!entry) return null;
  return {
    body: await readFile(path.join(publicRoot, entry[0]), "utf8"),
    contentType: entry[1],
  };
}

const identity = await runStore("Identity");
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
      sendJson(response, 200, { ok: true, service: "homelab-secret-ui", version: serviceVersion, bind: host });
      return;
    }

    if (request.method === "GET" && pathname === "/") {
      const page = indexTemplate
        .replaceAll("__CSRF_TOKEN__", csrfToken)
        .replaceAll("__SERVICE_MODE__", serviceMode ? "1" : "0")
        .replaceAll("__WINDOWS_USER__", escapeHtml(identity.user || "Windows-Benutzer"));
      sendText(response, 200, page, "text/html; charset=utf-8", {
        "Set-Cookie": sessionCookie + "=" + sessionToken + "; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800",
      });
      return;
    }

    if (request.method === "GET" && (pathname === "/app.css" || pathname === "/app.js")) {
      const asset = await getStaticAsset(pathname);
      sendText(response, 200, asset.body, asset.contentType);
      return;
    }

    if (request.method === "GET" && pathname === "/api/status") {
      if (!hasSession(request)) {
        sendJson(response, 401, { error: "Sitzung fehlt." });
        return;
      }
      sendJson(response, 200, await runStore("Identity"));
      return;
    }

    if (request.method === "GET" && pathname === "/api/records") {
      if (!hasSession(request)) {
        sendJson(response, 401, { error: "Sitzung fehlt." });
        return;
      }
      sendJson(response, 200, await runStore("List"));
      return;
    }

    if (request.method === "POST" && pathname === "/api/records") {
      if (!isAuthorizedMutation(request)) {
        sendJson(response, 403, { error: "Ungültige lokale Sitzung." });
        return;
      }
      const body = await readJsonBody(request);
      const created = await runStore("Create", { input: body });
      if (body && typeof body === "object") body.secret = null;
      sendJson(response, 201, created);
      return;
    }

    const recordMatch = pathname.match(/^\/api\/records\/([0-9a-fA-F-]{36})\/(copy|delete|update)$/);
    if (request.method === "POST" && recordMatch) {
      if (!isAuthorizedMutation(request)) {
        sendJson(response, 403, { error: "Ungültige lokale Sitzung." });
        return;
      }
      const body = await readJsonBody(request);
      if (recordMatch[2] === "copy") {
        sendJson(response, 200, await runStore("Copy", {
          id: recordMatch[1],
          clearAfterSeconds: 30,
        }));
      } else if (recordMatch[2] === "delete") {
        sendJson(response, 200, await runStore("Delete", { id: recordMatch[1] }));
      } else {
        const updated = await runStore("Update", {
          id: recordMatch[1],
          input: body,
        });
        if (body && typeof body === "object") body.secret = null;
        sendJson(response, 200, updated);
      }
      return;
    }

    if (request.method === "POST" && pathname === "/api/shutdown") {
      if (!isAuthorizedMutation(request)) {
        sendJson(response, 403, { error: "Ungültige lokale Sitzung." });
        return;
      }
      if (serviceMode) {
        sendJson(response, 409, { error: "Der automatisch gestartete Dienst wird über die Windows-Aufgabenplanung verwaltet." });
        return;
      }
      await readJsonBody(request);
      sendJson(response, 200, { ok: true });
      setTimeout(() => server.close(), 100);
      return;
    }

    sendJson(response, 404, { error: "Nicht gefunden." });
  } catch (error) {
    const known = error?.message === "REQUEST_TOO_LARGE" ? "Anfrage zu groß." :
      error?.message === "INVALID_JSON" ? "Ungültige Anfrage." :
      error?.message || "Lokaler Fehler.";
    sendJson(response, 400, { error: known });
  }
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    console.error("Port " + port + " wird bereits verwendet. Secret UI wurde nicht gestartet.");
  } else {
    console.error("Secret UI konnte nicht gestartet werden: " + error.message);
  }
  process.exitCode = 1;
});

server.listen(port, host, () => {
  console.log("Homelab Secret UI: " + origin);
  console.log("Windows-Kontext: " + identity.user);
  console.log("Nur dieses Fenster schließen oder Strg+C drücken, um den Dienst zu beenden.");

  if (process.env.HOMELAB_SECRET_UI_NO_OPEN !== "1") {
    const opener = spawn("rundll32.exe", ["url.dll,FileProtocolHandler", origin], {
      detached: true,
      windowsHide: true,
      stdio: "ignore",
    });
    opener.unref();
  }
});

process.on("SIGINT", () => server.close(() => process.exit(0)));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
