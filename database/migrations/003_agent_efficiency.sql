CREATE TABLE IF NOT EXISTS learning_candidates (
    id TEXT PRIMARY KEY,
    system_id TEXT REFERENCES systems(id),
    candidate_type TEXT NOT NULL
        CHECK (candidate_type IN ('runbook', 'skill', 'automation', 'policy', 'knowledge')),
    title TEXT NOT NULL,
    trigger TEXT NOT NULL,
    proposed_change TEXT NOT NULL,
    evidence TEXT NOT NULL,
    validation_plan TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'proposed'
        CHECK (status IN ('proposed', 'approved', 'rejected', 'applied')),
    source TEXT NOT NULL,
    created_at TEXT NOT NULL,
    reviewed_at TEXT,
    review_reference TEXT,
    validation TEXT,
    applied_change_id TEXT REFERENCES changes(id),
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_learning_candidates_status
ON learning_candidates(status, created_at DESC);

CREATE TABLE IF NOT EXISTS task_contracts (
    id TEXT PRIMARY KEY,
    target_thread_id TEXT NOT NULL,
    objective TEXT NOT NULL,
    success_criteria_json TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'waiting', 'blocked', 'completed', 'cancelled')),
    current_step TEXT,
    wait_reason TEXT,
    wait_job_id TEXT,
    verification TEXT,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_task_contracts_one_open_per_thread
ON task_contracts(target_thread_id)
WHERE status IN ('active', 'waiting', 'blocked');

CREATE INDEX IF NOT EXISTS idx_task_contracts_status
ON task_contracts(status, updated_at DESC);

CREATE TABLE IF NOT EXISTS task_contract_events (
    id TEXT PRIMARY KEY,
    contract_id TEXT NOT NULL REFERENCES task_contracts(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL
        CHECK (event_type IN ('created', 'progressed', 'waiting', 'resumed', 'blocked', 'completed', 'cancelled')),
    from_status TEXT,
    to_status TEXT NOT NULL,
    summary TEXT NOT NULL,
    source TEXT NOT NULL,
    occurred_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_task_contract_events_history
ON task_contract_events(contract_id, occurred_at);

INSERT OR IGNORE INTO schema_migrations(version, applied_at)
VALUES (3, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
