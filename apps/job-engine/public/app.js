const csrf = document.querySelector('meta[name="csrf-token"]').content;
const state = {
  jobs: [],
  oneTimeJobs: [],
  activeTests: [],
  jobNames: {},
  runs: [],
  runsPage: { total: 0, limit: 100, offset: 0, has_previous: false, has_next: false },
  engine: {},
};
const $ = (id) => document.getElementById(id);

async function api(path, body) {
  const options = body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
    body: JSON.stringify(body),
  };
  const response = await fetch(path, options);
  const value = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(value.error || `HTTP ${response.status}`);
  return value;
}

function notice(message, error = false) {
  const element = $("notice");
  element.textContent = message;
  element.classList.remove("hidden", "error");
  if (error) element.classList.add("error");
  clearTimeout(notice.timer);
  notice.timer = setTimeout(() => element.classList.add("hidden"), 5000);
}

function formatDate(value) {
  return value ? new Intl.DateTimeFormat("de-DE", { dateStyle: "short", timeStyle: "medium" }).format(new Date(value)) : "–";
}

function statusLabel(status) {
  return ({ succeeded: "Erfolgreich", failed: "Fehlgeschlagen", running: "Läuft", timed_out: "Zeitlimit", skipped: "Übersprungen", abandoned: "Abgebrochen" })[status] || status || "Noch nie";
}

function wakeStatusLabel(status) {
  return ({
    not_requested: "–",
    pending: "Wartet",
    retrying: "Neuer Versuch",
    running: "Reaktiviert",
    succeeded: "Fortgesetzt",
    failed: "Fehlgeschlagen",
  })[status] || status || "–";
}

function button(label, className, handler) {
  const element = document.createElement("button");
  element.type = "button";
  element.textContent = label;
  element.className = className;
  element.addEventListener("click", handler);
  return element;
}

function renderJobs() {
  const root = $("jobs");
  root.replaceChildren();
  $("empty-jobs").classList.toggle("hidden", state.jobs.length !== 0);
  for (const job of state.jobs) {
    const card = document.createElement("article");
    card.className = "job-card";

    const top = document.createElement("div");
    top.className = "job-top";
    const copy = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = job.name;
    const description = document.createElement("p");
    description.textContent = job.description || job.command_path;
    copy.append(title, description);
    const badge = document.createElement("span");
    badge.className = `badge ${job.enabled ? "active" : "disabled"}`;
    badge.textContent = job.enabled ? "Aktiv" : "Inaktiv";
    top.append(copy, badge);

    const facts = document.createElement("dl");
    for (const [term, detail] of [
      ["Cron", `${job.schedule} · ${job.timezone}`],
      ["Nächster Lauf", formatDate(job.next_run_at)],
      ["Letzter Status", statusLabel(job.last_status)],
      ["Zeitlimit", `${job.timeout_seconds} Sekunden`],
      ["Sicherheitsklasse", job.safety_classification || "manual_only"],
      ["Vorprüfung", job.preflight_status || "pending"],
    ]) {
      const dt = document.createElement("dt"); dt.textContent = term;
      const dd = document.createElement("dd"); dd.textContent = detail;
      facts.append(dt, dd);
    }

    const actions = document.createElement("div");
    actions.className = "actions";
    actions.append(
      button("Jetzt starten", "primary small", async () => {
        if (!confirm(`Job „${job.name}“ jetzt wirklich starten?`)) return;
        try { await api(`/api/jobs/${job.id}/run`, {}); notice("Job wurde gestartet."); await refresh(0); } catch (error) { notice(error.message, true); }
      }),
      button("Vorprüfung", "ghost small", async () => {
        try {
          const result = await api(`/api/jobs/${job.id}/preflight`, {});
          notice(result.ok ? "Vorprüfung bestanden." : "Vorprüfung fehlgeschlagen.", !result.ok);
          await refresh();
        } catch (error) { notice(error.message, true); }
      }),
      button("Bearbeiten", "ghost small", () => openJob(job)),
      button(job.enabled ? "Deaktivieren" : "Aktivieren", "ghost small", async () => {
        try {
          const update = { ...job, enabled: !job.enabled };
          if (!job.enabled && (!job.unattended || job.safety_classification === "manual_only")) {
            throw new Error("Job zuerst bearbeiten, unbeaufsichtigt zulassen und sicher klassifizieren.");
          }
          await api(`/api/jobs/${job.id}/update`, update);
          await refresh();
        } catch (error) { notice(error.message, true); }
      }),
      button("Löschen", "danger small", async () => {
        if (!confirm(`Job „${job.name}“ und seine Laufhistorie löschen?`)) return;
        try { await api(`/api/jobs/${job.id}/delete`, {}); notice("Job wurde gelöscht."); await refresh(); } catch (error) { notice(error.message, true); }
      }),
    );
    card.append(top, facts, actions);
    root.append(card);
  }
}

function renderTransientJobs() {
  const renderList = (rootId, emptyId, jobs, kind) => {
    const root = $(rootId);
    root.replaceChildren();
    $(emptyId).classList.toggle("hidden", jobs.length !== 0);
    for (const job of jobs) {
      const card = document.createElement("article");
      card.className = "job-card transient-card";
      const top = document.createElement("div");
      top.className = "job-top";
      const copy = document.createElement("div");
      const title = document.createElement("h3");
      title.textContent = job.name;
      const description = document.createElement("p");
      description.textContent = job.description || job.command_path;
      copy.append(title, description);
      const badge = document.createElement("span");
      badge.className = `badge ${kind === "active" ? "active" : "disabled"}`;
      badge.textContent = kind === "active" ? "Läuft" : "Geplant";
      top.append(copy, badge);
      const facts = document.createElement("dl");
      const entries = kind === "active" ? [
        ["Gestartet", formatDate(job.last_run_at)],
        ["Zeitlimit", `${job.timeout_seconds} Sekunden`],
      ] : [
        ["Termin", formatDate(job.scheduled_at)],
        ["Zeitzone", job.timezone],
        ["Task-Wakeup", job.wake_enabled ? "Gebunden" : "Aus"],
      ];
      for (const [term, detail] of entries) {
        const dt = document.createElement("dt"); dt.textContent = term;
        const dd = document.createElement("dd"); dd.textContent = detail;
        facts.append(dt, dd);
      }
      card.append(top, facts);
      root.append(card);
    }
  };
  renderList("active-tests", "empty-active-tests", state.activeTests, "active");
  renderList("one-time-jobs", "empty-one-time-jobs", state.oneTimeJobs, "one_time");
}

function renderRuns() {
  const root = $("runs");
  root.replaceChildren();
  $("empty-runs").classList.toggle("hidden", state.runs.length !== 0);
  const jobsById = new Map(Object.entries(state.jobNames));
  for (const run of state.runs) {
    const row = document.createElement("tr");
    const values = [
      jobsById.get(run.job_id) || "Gelöschter Job",
      statusLabel(run.status),
      formatDate(run.started_at || run.scheduled_for),
      ({ manual: "Manuell", schedule: "Zeitplan", one_time: "Einmalig", active_test: "Aktivtest" })[run.trigger_type] || run.trigger_type,
      wakeStatusLabel(run.wake_status),
      run.exit_code ?? "–",
    ];
    values.forEach((value, index) => {
      const cell = document.createElement("td");
      cell.textContent = value;
      if (index === 1) cell.className = `run-status ${run.status}`;
      row.append(cell);
    });
    const detailCell = document.createElement("td");
    const detail = [run.error, run.wake_error && `TASK-WAKEUP\n${run.wake_error}`, run.stdout && `STDOUT\n${run.stdout}`, run.stderr && `STDERR\n${run.stderr}`].filter(Boolean).join("\n\n");
    if (detail) detailCell.append(button("Anzeigen", "ghost small", () => { $("log-output").textContent = detail; $("log-dialog").showModal(); }));
    else detailCell.textContent = "–";
    row.append(detailCell);
    root.append(row);
  }

  const page = state.runsPage;
  const start = page.total > 0 ? page.offset + 1 : 0;
  const end = page.offset + state.runs.length;
  $("runs-page-info").textContent = `${start}–${end} von ${page.total}`;
  $("runs-prev").disabled = !page.has_previous;
  $("runs-next").disabled = !page.has_next;
  $("runs-pagination").classList.toggle("hidden", page.total === 0);
}

async function refresh(runsOffset = state.runsPage.offset) {
  try {
    const data = await api(`/api/state?runs_offset=${encodeURIComponent(runsOffset)}`);
    state.jobs = data.jobs;
    state.oneTimeJobs = data.one_time_jobs || [];
    state.activeTests = data.active_tests || [];
    state.jobNames = data.job_names || {};
    state.runs = data.runs;
    state.runsPage = data.runs_page || { total: data.runs.length, limit: 100, offset: 0, has_previous: false, has_next: false };
    state.engine = data.engine;
    $("engine-status").textContent = `Bereit · ${data.engine.active_jobs} Jobs · ${data.engine.active_wakes || 0} Task-Wakeups · ${data.engine.execution_identity}`;
    $("engine-status").classList.add("online");
    renderJobs();
    renderTransientJobs();
    renderRuns();
  } catch (error) {
    $("engine-status").textContent = "Nicht erreichbar";
    notice(error.message, true);
  }
}

function openJob(job = null) {
  $("dialog-title").textContent = job ? "Job bearbeiten" : "Neuer Job";
  $("job-id").value = job?.id || "";
  $("name").value = job?.name || "";
  $("description").value = job?.description || "";
  $("schedule").value = job?.schedule || "0 * * * *";
  $("timezone").value = job?.timezone || "Europe/Berlin";
  $("command-type").value = job?.command_type || "powershell";
  $("command-path").value = job?.command_path || "";
  $("arguments").value = (job?.arguments || []).join("\n");
  $("working-directory").value = job?.working_directory || "";
  $("timeout").value = job?.timeout_seconds || 900;
  $("misfire-policy").value = job?.misfire_policy || "run_once";
  $("safety-classification").value = job?.safety_classification || "manual_only";
  $("required-credential-refs").value = (job?.required_credential_refs || []).join("\n");
  $("required-endpoints").value = (job?.required_endpoints || []).map((item) => `${item.host}:${item.port}`).join("\n");
  $("expected-artifacts").value = (job?.expected_artifacts || []).join("\n");
  $("capture-output").checked = Boolean(job?.capture_output);
  $("unattended").checked = Boolean(job?.unattended);
  $("enabled").checked = Boolean(job?.enabled);
  $("job-dialog").showModal();
}

$("job-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const id = $("job-id").value;
  const commandPath = $("command-path").value.trim();
  try {
    const requiredEndpoints = $("required-endpoints").value.split(/\r?\n/).filter(Boolean).map((line) => {
      const match = line.trim().match(/^(?:\[([^\]]+)\]|([^:]+)):(\d+)$/);
      if (!match) throw new Error(`Ungültiger Endpunkt: ${line}`);
      return { host: match[1] || match[2], port: Number(match[3]) };
    });
    const payload = {
    name: $("name").value,
    description: $("description").value,
    schedule: $("schedule").value,
    timezone: $("timezone").value,
    command_type: $("command-type").value,
    command_path: commandPath,
    arguments: $("arguments").value.split(/\r?\n/).filter((line) => line.length),
    working_directory: $("working-directory").value.trim() || commandPath.replace(/[\\/][^\\/]+$/, ""),
    timeout_seconds: Number($("timeout").value),
    overlap_policy: "skip",
    misfire_policy: $("misfire-policy").value,
    safety_classification: $("safety-classification").value,
    required_credential_refs: $("required-credential-refs").value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean),
    required_endpoints: requiredEndpoints,
    expected_artifacts: $("expected-artifacts").value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean),
    capture_output: $("capture-output").checked,
    unattended: $("unattended").checked,
    enabled: $("enabled").checked,
    };
    await api(id ? `/api/jobs/${id}/update` : "/api/jobs", payload);
    $("job-dialog").close();
    notice(id ? "Job wurde aktualisiert." : "Job wurde angelegt.");
    await refresh();
  } catch (error) { notice(error.message, true); }
});

$("new-job").addEventListener("click", () => openJob());
$("refresh").addEventListener("click", () => refresh());
$("runs-prev").addEventListener("click", () => refresh(Math.max(0, state.runsPage.offset - state.runsPage.limit)));
$("runs-next").addEventListener("click", () => refresh(state.runsPage.offset + state.runsPage.limit));
$("close-dialog").addEventListener("click", () => $("job-dialog").close());
$("cancel-dialog").addEventListener("click", () => $("job-dialog").close());
$("close-log").addEventListener("click", () => $("log-dialog").close());
setInterval(refresh, 15_000);
refresh();
