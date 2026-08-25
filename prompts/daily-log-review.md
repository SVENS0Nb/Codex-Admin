# Daily Homelab log review

Analyze only `daily-log-review-input.json` from the current working directory.
Do not access the network, remote systems, credential stores, browsers, or other
files. Do not run a repair, restart, update, configuration change, acknowledgement,
log deletion, or any other mutation.

The input contains sanitized, preselected events from the last 24 hours, an
approved read-only collector registry, and coverage records for every enabled
system source. Produce a concise German operations report using the supplied JSON
schema. Include every distinct enabled `collector_registry.system_id` exactly once
in `systems`; never infer health for a source whose coverage failed or is absent.

Rules:

- Correlate related messages across sources and combine duplicates into one finding.
- Distinguish actual failures from harmless warnings, historic lines, restarts,
  expected disconnects, and secondary symptoms.
- Decide autonomously whether an issue is genuinely significant or actionable now.
  Put only such issues in `findings`; do not turn every warning or error-shaped log
  line into a user-facing finding.
- For every finding, state why it crossed the reporting threshold in
  `significance_reason`, classify its cross-run `trend`, and set
  `promoted_from_watch` when the prior review context shows that it was previously
  retained below the reporting threshold.
- Put isolated, low-impact anomalies without demonstrated persistence or meaningful
  effect in `watch_items`. Watch items do not change the overall or per-system
  status and must not contain a remediation proposal. Give each watch item a clear
  cross-run `trend` and an `escalation_condition` describing what recurrence,
  frequency, impact, or context would make it a finding.
- Compare current events with `prior_review_context.observations`. Escalate a watch
  item when it recurs across review days, becomes more frequent, affects multiple
  systems, or develops a meaningful operational or security impact. If
  `prior_review_context.available` is false, add its sanitized error as a coverage
  gap and do not claim that a current anomaly is non-recurring.
- Prioritize outages, security events, backup failures, storage pressure, repeated
  crashes, certificate problems, network instability, failed updates, and persistent
  service degradation.
- Preserve enough sanitized evidence for an administrator to verify the conclusion,
  but never reconstruct or speculate about secrets.
- Use `notable_events` only for confirmed successful, healthy, or expected outcomes
  worth showing under "Erfolgreich geprüft". Minor negative anomalies belong in
  `watch_items`, not in `notable_events`.
- Report missing or failed log sources as coverage gaps, not as proof that the system
  is healthy.
- Every recommendation is a proposal only. Set `repair_requires_confirmation` to
  true for every finding. Never claim that a repair was performed.
- If no significant or actionable error is present, return an empty findings array
  and state that explicitly in the executive summary. Minor watch items may still
  be returned separately for internal trend monitoring.
