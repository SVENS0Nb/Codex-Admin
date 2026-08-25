ALTER TABLE jobs ADD COLUMN wake_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE jobs ADD COLUMN wake_thread_id TEXT;
ALTER TABLE jobs ADD COLUMN wake_working_directory TEXT;
ALTER TABLE jobs ADD COLUMN wake_sandbox_mode TEXT;
ALTER TABLE jobs ADD COLUMN wake_approval_policy TEXT;
ALTER TABLE jobs ADD COLUMN wake_condition TEXT NOT NULL DEFAULT 'always';
ALTER TABLE jobs ADD COLUMN wake_decision TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE jobs ADD COLUMN wake_context_json TEXT;
ALTER TABLE jobs ADD COLUMN wake_decided_at TEXT;

ALTER TABLE runs ADD COLUMN wake_status TEXT NOT NULL DEFAULT 'not_requested';
ALTER TABLE runs ADD COLUMN wake_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE runs ADD COLUMN wake_next_attempt_at TEXT;
ALTER TABLE runs ADD COLUMN wake_started_at TEXT;
ALTER TABLE runs ADD COLUMN wake_finished_at TEXT;
ALTER TABLE runs ADD COLUMN wake_error TEXT;

CREATE INDEX idx_runs_wake_due ON runs(wake_status, wake_next_attempt_at);
