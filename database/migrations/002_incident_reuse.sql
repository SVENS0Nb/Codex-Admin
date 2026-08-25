ALTER TABLE decisions ADD COLUMN system_id TEXT REFERENCES systems(id);

CREATE INDEX IF NOT EXISTS idx_incidents_system_status
ON incidents(system_id, status, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_decisions_system_status
ON decisions(system_id, status, decided_at DESC);

CREATE TABLE IF NOT EXISTS incident_events (
    id TEXT PRIMARY KEY,
    incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL
        CHECK (event_type IN ('opened', 'updated', 'status_changed', 'resolved', 'reopened')),
    from_status TEXT CHECK (from_status IS NULL OR from_status IN ('open', 'monitoring', 'resolved')),
    to_status TEXT NOT NULL CHECK (to_status IN ('open', 'monitoring', 'resolved')),
    summary TEXT NOT NULL,
    details TEXT,
    source TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    recorded_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_incident_events_history
ON incident_events(incident_id, occurred_at DESC);

INSERT OR IGNORE INTO schema_migrations(version, applied_at)
VALUES (2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
