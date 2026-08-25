const csrfToken = document.querySelector('meta[name="csrf-token"]').content;
const serviceMode = document.querySelector('meta[name="service-mode"]').content === "1";
const form = document.querySelector("#secret-form");
const intakeKicker = document.querySelector("#intake-kicker");
const intakeTitle = document.querySelector("#intake-title");
const systemInput = document.querySelector("#system");
const internalEndpointInput = document.querySelector("#internal-endpoint");
const externalEndpointInput = document.querySelector("#external-endpoint");
const labelInput = document.querySelector("#label");
const usernameInput = document.querySelector("#username");
const notesInput = document.querySelector("#notes");
const formSubmit = document.querySelector("#form-submit");
const submitIcon = document.querySelector("#submit-icon");
const submitLabel = document.querySelector("#submit-label");
const cancelEdit = document.querySelector("#cancel-edit");
const recordsRoot = document.querySelector("#records");
const emptyState = document.querySelector("#empty-state");
const recordCount = document.querySelector("#record-count");
const searchInput = document.querySelector("#search");
const typeFilter = document.querySelector("#type-filter");
const systemOptions = document.querySelector("#system-options");
const secretInput = document.querySelector("#secret");
const secretHelp = document.querySelector("#secret-help");
const showSecret = document.querySelector("#show-secret");
const deleteDialog = document.querySelector("#delete-dialog");
const deleteTitle = document.querySelector("#delete-title");
const toast = document.querySelector("#toast");
const shutdownButton = document.querySelector("#shutdown");
const offline = document.querySelector("#offline");

if (serviceMode) {
  shutdownButton.hidden = true;
}

const typeLabels = {
  password: "Passwort",
  api_key: "API-Key",
  totp: "TOTP",
};

let records = [];
let pendingDelete = null;
let toastTimer = null;
let editingId = null;
let editingOriginalType = null;

async function api(path, options = {}) {
  const request = {
    method: options.method || "GET",
    credentials: "same-origin",
    headers: {},
  };
  if (request.method !== "GET") {
    request.headers["Content-Type"] = "application/json";
    request.headers["X-CSRF-Token"] = csrfToken;
    request.body = JSON.stringify(options.body || {});
  }

  const response = await fetch(path, request);
  let result;
  try {
    result = await response.json();
  } catch {
    result = {};
  }
  if (!response.ok) {
    throw new Error(result.error || "Lokale Anfrage fehlgeschlagen.");
  }
  return result;
}

function notify(message, isError = false) {
  clearTimeout(toastTimer);
  toast.textContent = message;
  toast.classList.toggle("error", isError);
  toast.classList.add("visible");
  toastTimer = setTimeout(() => toast.classList.remove("visible"), 3200);
}

function normalize(value) {
  return String(value || "").toLocaleLowerCase("de");
}

function filteredRecords() {
  const query = normalize(searchInput.value).trim();
  const selectedType = typeFilter.value;
  return records.filter((record) => {
    const typeMatches = selectedType === "all" || record.type === selectedType;
    const searchable = [
      record.system,
      record.internalEndpoint,
      record.externalEndpoint,
      record.label,
      record.username,
      record.notes,
    ]
      .map(normalize)
      .join(" ");
    return typeMatches && (!query || searchable.includes(query));
  });
}

function makeElement(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function navigableEndpoint(value) {
  try {
    const parsed = new URL(value);
    if (!["http:", "https:"].includes(parsed.protocol)) return null;
    if (parsed.username || parsed.password) return null;
    return parsed.href;
  } catch {
    return null;
  }
}

function appendEndpoint(container, kind, value) {
  if (!value) return;
  const endpointLine = makeElement("p", "record-endpoint");
  endpointLine.append(makeElement("span", "endpoint-kind", kind));
  endpointLine.append(makeElement("span", "record-endpoint-value", value));
  const href = navigableEndpoint(value);
  if (href) {
    const link = makeElement("a", "endpoint-link", "Öffnen");
    link.href = href;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    endpointLine.append(link);
  }
  container.append(endpointLine);
}

function makeRecordCard(record) {
  const card = makeElement("article", "record-card");
  const main = makeElement("div", "record-main");
  const topLine = makeElement("div", "record-topline");
  const title = makeElement("h4", "record-label", record.label);
  const badge = makeElement("span", "type-badge " + (record.type === "totp" ? "totp" : ""), typeLabels[record.type]);
  topLine.append(title, badge);
  main.append(topLine);

  if (record.username) {
    main.append(makeElement("p", "record-username", record.username));
  }
  appendEndpoint(main, "Intern", record.internalEndpoint);
  appendEndpoint(main, "Extern", record.externalEndpoint);
  if (record.notes) {
    main.append(makeElement("p", "record-notes", record.notes));
  }

  const actions = makeElement("div", "record-actions");
  const copyButton = makeElement(
    "button",
    "copy-action",
    record.type === "totp" ? "TOTP kopieren" : "Geheimwert kopieren",
  );
  copyButton.type = "button";
  copyButton.addEventListener("click", async () => {
    copyButton.disabled = true;
    try {
      await api("/api/records/" + record.id + "/copy", { method: "POST" });
      notify((record.type === "totp" ? "Aktueller TOTP-Code" : typeLabels[record.type]) +
        " kopiert · automatische Löschung in 30 Sekunden");
    } catch (error) {
      notify(error.message, true);
    } finally {
      copyButton.disabled = false;
    }
  });

  const editButton = makeElement("button", "edit-action", "Bearbeiten");
  editButton.type = "button";
  editButton.addEventListener("click", () => beginEdit(record));

  const deleteButton = makeElement("button", "delete-action", "×");
  deleteButton.type = "button";
  deleteButton.setAttribute("aria-label", record.label + " löschen");
  deleteButton.addEventListener("click", () => {
    pendingDelete = record;
    deleteTitle.textContent = "„" + record.label + "“ wirklich löschen?";
    deleteDialog.showModal();
  });

  actions.append(copyButton, editButton, deleteButton);
  card.append(main, actions);
  return card;
}

function render() {
  recordsRoot.replaceChildren();
  const visible = filteredRecords();
  recordCount.textContent = String(records.length);

  const systems = new Map();
  for (const record of visible) {
    const key = record.system || "Ohne System";
    if (!systems.has(key)) systems.set(key, []);
    systems.get(key).push(record);
  }

  for (const [system, systemRecords] of systems) {
    const group = makeElement("section", "system-group");
    const groupHeading = makeElement("div", "system-heading");
    const title = makeElement("h3", "system-title", system);
    const groupControls = makeElement("div", "system-controls");
    const count = makeElement(
      "span",
      "system-count",
      systemRecords.length + (systemRecords.length === 1 ? " Wert" : " Werte"),
    );
    const addButton = makeElement("button", "system-add", "+ Weiterer Wert");
    addButton.type = "button";
    addButton.addEventListener("click", () => {
      const internalEndpoint = systemRecords.find((record) => record.internalEndpoint)?.internalEndpoint || "";
      const externalEndpoint = systemRecords.find((record) => record.externalEndpoint)?.externalEndpoint || "";
      resetEditor(system, internalEndpoint, externalEndpoint);
      labelInput.focus();
    });
    groupControls.append(count, addButton);
    groupHeading.append(title, groupControls);
    group.append(groupHeading);
    for (const record of systemRecords) {
      group.append(makeRecordCard(record));
    }
    recordsRoot.append(group);
  }

  emptyState.hidden = visible.length > 0;
  const emptyTitle = emptyState.querySelector("h3");
  const emptyText = emptyState.querySelector("p");
  if (records.length > 0 && visible.length === 0) {
    emptyTitle.textContent = "Keine passenden Einträge";
    emptyText.textContent = "Passe Suche oder Filter an.";
  } else {
    emptyTitle.textContent = "Noch keine Zugänge hinterlegt";
    emptyText.textContent = "Lege links den ersten verschlüsselten Eintrag an.";
  }

  const systemsForInput = [...new Set(records.map((record) => record.system))]
    .filter(Boolean)
    .sort((left, right) => left.localeCompare(right, "de"));
  systemOptions.replaceChildren();
  for (const system of systemsForInput) {
    const option = document.createElement("option");
    option.value = system;
    systemOptions.append(option);
  }
}

async function loadRecords() {
  const result = await api("/api/records");
  records = Array.isArray(result) ? result : [];
  render();
}

function resetEditor(system = "", internalEndpoint = "", externalEndpoint = "") {
  editingId = null;
  editingOriginalType = null;
  form.reset();
  systemInput.value = system;
  internalEndpointInput.value = internalEndpoint;
  externalEndpointInput.value = externalEndpoint;
  secretInput.type = "password";
  secretInput.required = true;
  intakeKicker.textContent = "Neuer Eintrag";
  intakeTitle.textContent = "Zugang sicher hinterlegen";
  submitIcon.textContent = "+";
  submitLabel.textContent = "Sicher speichern";
  cancelEdit.hidden = true;
  updateSecretPrompt();
  formSubmit.disabled = false;
}

function beginEdit(record) {
  editingId = record.id;
  editingOriginalType = record.type;
  systemInput.value = record.system || "";
  internalEndpointInput.value = record.internalEndpoint || "";
  externalEndpointInput.value = record.externalEndpoint || "";
  labelInput.value = record.label || "";
  usernameInput.value = record.username || "";
  notesInput.value = record.notes || "";
  const typeInput = form.querySelector('input[name="type"][value="' + record.type + '"]');
  if (typeInput) typeInput.checked = true;
  secretInput.value = "";
  showSecret.checked = false;
  secretInput.type = "password";
  intakeKicker.textContent = "Eintrag bearbeiten";
  intakeTitle.textContent = record.label;
  submitIcon.textContent = "✓";
  submitLabel.textContent = "Änderungen speichern";
  cancelEdit.hidden = false;
  updateSecretPrompt();
  form.scrollIntoView({ behavior: "smooth", block: "start" });
  labelInput.focus({ preventScroll: true });
}

function updateSecretPrompt() {
  const type = new FormData(form).get("type");
  if (editingId && type === editingOriginalType) {
    secretInput.required = false;
    secretInput.placeholder = "Leer lassen, um den bisherigen Wert zu behalten";
    secretHelp.textContent = "Nur ausfüllen, wenn der gespeicherte Geheimwert ersetzt werden soll.";
    return;
  }

  secretInput.required = true;
  if (editingId) {
    secretInput.placeholder = "Neuen Geheimwert für den Typwechsel eingeben";
    secretHelp.textContent = "Bei einem Typwechsel ist ein neuer passender Geheimwert erforderlich.";
    return;
  }

  if (type === "totp") {
    secretInput.placeholder = "Base32-Seed oder otpauth://totp/…";
    secretHelp.textContent = "QR-Code-Seed oder vollständige TOTP-URI; der aktuelle Code wird später lokal erzeugt.";
  } else if (type === "api_key") {
    secretInput.placeholder = "API-Key oder Zugriffstoken einfügen";
    secretHelp.textContent = "Der API-Key wird nach dem Speichern nicht mehr angezeigt.";
  } else {
    secretInput.placeholder = "Passwort einfügen";
    secretHelp.textContent = "Das Passwort wird nach dem Speichern nicht mehr angezeigt.";
  }
}

form.addEventListener("change", (event) => {
  if (event.target.name === "type") updateSecretPrompt();
});

showSecret.addEventListener("change", () => {
  secretInput.type = showSecret.checked ? "text" : "password";
});

cancelEdit.addEventListener("click", () => {
  resetEditor();
  systemInput.focus();
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const submitButton = form.querySelector('button[type="submit"]');
  submitButton.disabled = true;
  const data = new FormData(form);
  const payload = {
    system: data.get("system"),
    internalEndpoint: data.get("internalEndpoint"),
    externalEndpoint: data.get("externalEndpoint"),
    label: data.get("label"),
    username: data.get("username"),
    type: data.get("type"),
    secret: data.get("secret"),
    notes: data.get("notes"),
  };
  const editedId = editingId;

  try {
    const apiEndpoint = editedId ? "/api/records/" + editedId + "/update" : "/api/records";
    await api(apiEndpoint, { method: "POST", body: payload });
    payload.secret = null;
    resetEditor();
    await loadRecords();
    notify(editedId ?
      "Änderungen wurden verschlüsselt gespeichert." :
      "Zugang wurde mit Windows DPAPI verschlüsselt gespeichert.");
    systemInput.focus();
  } catch (error) {
    payload.secret = null;
    notify(error.message, true);
  } finally {
    submitButton.disabled = false;
  }
});

searchInput.addEventListener("input", render);
typeFilter.addEventListener("change", render);

deleteDialog.addEventListener("close", async () => {
  if (deleteDialog.returnValue !== "confirm" || !pendingDelete) {
    pendingDelete = null;
    return;
  }

  const record = pendingDelete;
  pendingDelete = null;
  try {
    await api("/api/records/" + record.id + "/delete", { method: "POST" });
    if (editingId === record.id) resetEditor();
    await loadRecords();
    notify("„" + record.label + "“ wurde dauerhaft entfernt.");
  } catch (error) {
    notify(error.message, true);
  }
});

shutdownButton.addEventListener("click", async () => {
  if (!window.confirm("Lokalen Secret-UI-Dienst jetzt beenden?")) return;
  try {
    await api("/api/shutdown", { method: "POST" });
    offline.hidden = false;
  } catch (error) {
    notify(error.message, true);
  }
});

resetEditor();
loadRecords().catch((error) => notify(error.message, true));
