ALTER TABLE learning_candidates ADD COLUMN review_due_at TEXT;

UPDATE learning_candidates
SET review_due_at = strftime('%Y-%m-%dT%H:%M:%fZ', created_at, '+14 days')
WHERE review_due_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_learning_candidates_review_due
ON learning_candidates(status, review_due_at);

INSERT OR IGNORE INTO schema_migrations(version, applied_at)
VALUES (4, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
