import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const paths = {
  server: path.join(appRoot, "server.mjs"),
  client: path.join(appRoot, "public", "app.js"),
  html: path.join(appRoot, "public", "index.html"),
  css: path.join(appRoot, "public", "app.css"),
  store: path.join(appRoot, "backend", "SecretUiStore.ps1"),
};

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

for (const file of [paths.server, paths.client]) {
  const result = spawnSync(process.execPath, ["--check", file], {
    encoding: "utf8",
    windowsHide: true,
  });
  assert(result.status === 0, result.stderr || ("Syntax check failed: " + file));
}

const [server, client, html, css] = await Promise.all([
  readFile(paths.server, "utf8"),
  readFile(paths.client, "utf8"),
  readFile(paths.html, "utf8"),
  readFile(paths.css, "utf8"),
]);

assert(server.includes('const host = "127.0.0.1"'), "Server must bind to literal loopback.");
assert(server.includes('service: "homelab-secret-ui"'), "Health endpoint must identify the Secret UI service.");
assert(server.includes("version: serviceVersion"), "Health endpoint must expose the package version.");
assert(!server.includes('"0.0.0.0"'), "Wildcard IPv4 binding is forbidden.");
assert(!server.match(/listen\s*\([^,]+,\s*["']::["']/), "Wildcard IPv6 binding is forbidden.");
for (const forbidden of ["localStorage", "sessionStorage", "innerHTML", "outerHTML", "insertAdjacentHTML"]) {
  assert(!client.includes(forbidden), "Client must not use " + forbidden + ".");
}
for (const header of [
  "Content-Security-Policy",
  "X-Frame-Options",
  "Cross-Origin-Opener-Policy",
  "Cross-Origin-Resource-Policy",
  "Referrer-Policy",
]) {
  assert(server.includes(header), "Missing security header: " + header);
}
assert(html.includes("__CSRF_TOKEN__"), "HTML must contain a CSRF placeholder.");
assert(html.includes("__SERVICE_MODE__"), "HTML must contain a service-mode placeholder.");
assert(html.includes("__WINDOWS_USER__"), "HTML must contain a Windows identity placeholder.");
assert(css.length > 2000, "Stylesheet appears incomplete.");

const selfTest = spawnSync("pwsh.exe", [
  "-NoLogo",
  "-NoProfile",
  "-NonInteractive",
  "-ExecutionPolicy",
  "RemoteSigned",
  "-File",
  paths.store,
  "-Action",
  "SelfTest",
], {
  encoding: "utf8",
  windowsHide: true,
});
assert(selfTest.status === 0, selfTest.stderr || "PowerShell backend self-test failed.");
const result = JSON.parse(selfTest.stdout.trim());
assert(result.ok === true, "PowerShell backend self-test did not pass.");

console.log("Secret UI build validation passed.");
