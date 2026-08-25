ALTER TABLE jobs ADD COLUMN command_sha256 TEXT;
ALTER TABLE jobs ADD COLUMN safety_classification TEXT NOT NULL DEFAULT 'manual_only';
ALTER TABLE jobs ADD COLUMN required_credential_refs_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE jobs ADD COLUMN required_endpoints_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE jobs ADD COLUMN expected_artifacts_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE jobs ADD COLUMN preflight_status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE jobs ADD COLUMN preflight_checked_at TEXT;
ALTER TABLE jobs ADD COLUMN preflight_json TEXT;
