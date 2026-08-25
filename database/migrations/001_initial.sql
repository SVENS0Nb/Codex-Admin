PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

INSERT OR IGNORE INTO schema_migrations(version, applied_at)
VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));

CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS systems (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    location TEXT,
    parent_system_id TEXT REFERENCES systems(id),
    stable_identifier TEXT,
    criticality TEXT NOT NULL DEFAULT 'normal'
        CHECK (criticality IN ('low', 'normal', 'high', 'critical')),
    lifecycle TEXT NOT NULL DEFAULT 'active'
        CHECK (lifecycle IN ('planned', 'active', 'maintenance', 'retired')),
    source TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    last_verified_at TEXT,
    valid_until TEXT,
    confidence REAL NOT NULL DEFAULT 0.8 CHECK (confidence BETWEEN 0 AND 1),
    notes TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS interfaces (
    id TEXT PRIMARY KEY,
    system_id TEXT NOT NULL REFERENCES systems(id) ON DELETE CASCADE,
    purpose TEXT NOT NULL,
    protocol TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER CHECK (port IS NULL OR port BETWEEN 1 AND 65535),
    username TEXT,
    tls_fingerprint_sha256 TEXT,
    ssh_host_key_fingerprint TEXT,
    credential_ref TEXT,
    source TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    last_verified_at TEXT,
    valid_until TEXT,
    confidence REAL NOT NULL DEFAULT 0.8 CHECK (confidence BETWEEN 0 AND 1),
    updated_at TEXT NOT NULL,
    UNIQUE(system_id, purpose, address, port)
);

CREATE TABLE IF NOT EXISTS services (
    id TEXT PRIMARY KEY,
    system_id TEXT NOT NULL REFERENCES systems(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    product TEXT,
    version TEXT,
    desired_state TEXT,
    observed_state TEXT,
    management_interface_id TEXT REFERENCES interfaces(id),
    source TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    last_verified_at TEXT,
    valid_until TEXT,
    confidence REAL NOT NULL DEFAULT 0.8 CHECK (confidence BETWEEN 0 AND 1),
    notes TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dependencies (
    id TEXT PRIMARY KEY,
    from_system_id TEXT NOT NULL REFERENCES systems(id) ON DELETE CASCADE,
    to_system_id TEXT NOT NULL REFERENCES systems(id) ON DELETE CASCADE,
    relationship TEXT NOT NULL,
    source TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    last_verified_at TEXT,
    confidence REAL NOT NULL DEFAULT 0.8 CHECK (confidence BETWEEN 0 AND 1),
    notes TEXT,
    updated_at TEXT NOT NULL,
    UNIQUE(from_system_id, to_system_id, relationship)
);

CREATE TABLE IF NOT EXISTS access_profiles (
    id TEXT PRIMARY KEY,
    system_id TEXT NOT NULL REFERENCES systems(id) ON DELETE CASCADE,
    identity TEXT NOT NULL,
    method TEXT NOT NULL,
    scope TEXT NOT NULL,
    credential_ref TEXT,
    last_tested_at TEXT,
    test_result TEXT NOT NULL DEFAULT 'untested'
        CHECK (test_result IN ('verified', 'failed', 'untested', 'stale')),
    revocation TEXT,
    source TEXT NOT NULL,
    notes TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capabilities (
    id TEXT PRIMARY KEY,
    system_id TEXT NOT NULL REFERENCES systems(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    access_level TEXT NOT NULL,
    access_profile_id TEXT REFERENCES access_profiles(id),
    last_tested_at TEXT,
    test_result TEXT NOT NULL DEFAULT 'untested'
        CHECK (test_result IN ('verified', 'failed', 'untested', 'stale')),
    evidence TEXT,
    source TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(system_id, name)
);

CREATE TABLE IF NOT EXISTS facts (
    id TEXT PRIMARY KEY,
    system_id TEXT REFERENCES systems(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    fact_key TEXT NOT NULL,
    fact_value TEXT NOT NULL,
    source TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    last_verified_at TEXT,
    valid_until TEXT,
    confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'superseded', 'disputed')),
    supersedes_id TEXT REFERENCES facts(id),
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_facts_active
ON facts(system_id, fact_key, status);

CREATE TABLE IF NOT EXISTS observations (
    id TEXT PRIMARY KEY,
    system_id TEXT REFERENCES systems(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('ok', 'warning', 'critical', 'unknown')),
    summary TEXT NOT NULL,
    details TEXT,
    source TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    valid_until TEXT NOT NULL,
    confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    recorded_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_observations_current
ON observations(system_id, kind, valid_until DESC);

CREATE TABLE IF NOT EXISTS changes (
    id TEXT PRIMARY KEY,
    system_id TEXT REFERENCES systems(id),
    requested_by TEXT NOT NULL,
    approval_reference TEXT,
    summary TEXT NOT NULL,
    before_state TEXT,
    after_state TEXT,
    verification TEXT NOT NULL,
    rollback TEXT NOT NULL,
    result TEXT NOT NULL CHECK (result IN ('succeeded', 'failed', 'rolled_back', 'partial')),
    occurred_at TEXT NOT NULL,
    recorded_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_changes_recent ON changes(occurred_at DESC);

CREATE TABLE IF NOT EXISTS incidents (
    id TEXT PRIMARY KEY,
    system_id TEXT REFERENCES systems(id),
    title TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    status TEXT NOT NULL CHECK (status IN ('open', 'monitoring', 'resolved')),
    symptoms TEXT NOT NULL,
    root_cause TEXT,
    remediation TEXT,
    prevention TEXT,
    opened_at TEXT NOT NULL,
    resolved_at TEXT,
    source TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS maintenance (
    id TEXT PRIMARY KEY,
    system_id TEXT REFERENCES systems(id),
    category TEXT NOT NULL,
    title TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('open', 'scheduled', 'completed', 'deferred')),
    due_at TEXT,
    interval_days INTEGER CHECK (interval_days IS NULL OR interval_days > 0),
    verification TEXT,
    notes TEXT,
    source TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS decisions (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    context TEXT NOT NULL,
    decision TEXT NOT NULL,
    rationale TEXT NOT NULL,
    alternatives TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('proposed', 'active', 'superseded')),
    decided_at TEXT NOT NULL,
    source TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS knowledge_entries (
    id TEXT PRIMARY KEY,
    system_id TEXT REFERENCES systems(id),
    category TEXT NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    source_path TEXT NOT NULL,
    source_hash TEXT NOT NULL,
    last_verified_at TEXT,
    confidence REAL NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    updated_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_fts USING fts5(
    title,
    content,
    category,
    content='knowledge_entries',
    content_rowid='rowid',
    tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS knowledge_entries_ai AFTER INSERT ON knowledge_entries BEGIN
    INSERT INTO knowledge_fts(rowid, title, content, category)
    VALUES (new.rowid, new.title, new.content, new.category);
END;

CREATE TRIGGER IF NOT EXISTS knowledge_entries_ad AFTER DELETE ON knowledge_entries BEGIN
    INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, category)
    VALUES ('delete', old.rowid, old.title, old.content, old.category);
END;

CREATE TRIGGER IF NOT EXISTS knowledge_entries_au AFTER UPDATE ON knowledge_entries BEGIN
    INSERT INTO knowledge_fts(knowledge_fts, rowid, title, content, category)
    VALUES ('delete', old.rowid, old.title, old.content, old.category);
    INSERT INTO knowledge_fts(rowid, title, content, category)
    VALUES (new.rowid, new.title, new.content, new.category);
END;

CREATE TABLE IF NOT EXISTS context_snapshots (
    id TEXT PRIMARY KEY,
    generated_at TEXT NOT NULL,
    content_json TEXT NOT NULL,
    source_revision TEXT,
    expires_at TEXT NOT NULL
);

CREATE VIEW IF NOT EXISTS v_stale_facts AS
SELECT * FROM facts
WHERE status = 'active'
  AND valid_until IS NOT NULL
  AND valid_until <= strftime('%Y-%m-%dT%H:%M:%fZ', 'now');

CREATE VIEW IF NOT EXISTS v_access_matrix AS
SELECT
    ap.id,
    ap.system_id,
    s.name AS system_name,
    ap.identity,
    ap.method,
    ap.scope,
    ap.credential_ref,
    ap.last_tested_at,
    ap.test_result
FROM access_profiles ap
JOIN systems s ON s.id = ap.system_id;
