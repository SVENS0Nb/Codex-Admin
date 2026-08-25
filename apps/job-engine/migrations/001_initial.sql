CREATE TABLE jobs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  schedule TEXT NOT NULL,
  timezone TEXT NOT NULL,
  command_type TEXT NOT NULL CHECK(command_type IN ('powershell','executable')),
  command_path TEXT NOT NULL,
  arguments_json TEXT NOT NULL DEFAULT '[]',
  working_directory TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
  unattended INTEGER NOT NULL DEFAULT 0 CHECK(unattended IN (0,1)),
  timeout_seconds INTEGER NOT NULL DEFAULT 900,
  overlap_policy TEXT NOT NULL DEFAULT 'skip',
  misfire_policy TEXT NOT NULL DEFAULT 'run_once',
  capture_output INTEGER NOT NULL DEFAULT 0 CHECK(capture_output IN (0,1)),
  next_run_at TEXT,
  last_run_at TEXT,
  last_status TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  job_id TEXT NOT NULL,
  trigger_type TEXT NOT NULL,
  scheduled_for TEXT,
  started_at TEXT,
  finished_at TEXT,
  status TEXT NOT NULL,
  exit_code INTEGER,
  stdout TEXT,
  stderr TEXT,
  error TEXT,
  FOREIGN KEY(job_id) REFERENCES jobs(id) ON DELETE CASCADE
);

CREATE INDEX idx_jobs_due ON jobs(enabled, unattended, next_run_at);
CREATE INDEX idx_runs_job_started ON runs(job_id, started_at DESC);
