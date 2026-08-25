import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "homelab-knowledge-test-"));
const previousLocalAppData = process.env.LOCALAPPDATA;
process.env.LOCALAPPDATA = temporaryRoot;
const minimumSyntheticSystems = 8;
const minimumSyntheticServices = 4;

try {
  const database = await import(`../build/database.js?test=${Date.now()}`);
  const db = database.openKnowledgeDatabase();
  try {
    const synced = database.synchronizeKnowledgeBase(db);
    if (synced.counts.systems < minimumSyntheticSystems) throw new Error("Structured systems were not imported");
    if (synced.counts.services < minimumSyntheticServices) throw new Error("Structured service catalogue was not imported");

    const fact = database.recordFact(db, {
      system_id: "home_assistant",
      category: "test",
      fact_key: "database_test_fact",
      fact_value: "verified test value",
      source: "database test",
      confidence: 1,
      valid_for_hours: 1,
    });
    database.recordFact(db, {
      system_id: "home_assistant",
      category: "test",
      fact_key: "database_test_fact",
      fact_value: "verified replacement value",
      source: "database test",
      confidence: 1,
      valid_for_hours: 1,
    });
    const superseded = db.prepare("SELECT status FROM facts WHERE id = ?").get(fact.id);
    if (superseded.status !== "superseded") throw new Error("Fact history was not preserved");

    database.recordObservation(db, {
      system_id: "unifi",
      kind: "database_test",
      status: "ok",
      summary: "Structured observation test passed",
      source: "database test",
      confidence: 1,
      valid_for_hours: 1,
    });
    const observationBase = Date.now();
    database.recordObservation(db, {
      system_id: "unifi",
      kind: "database_latest_test",
      status: "warning",
      summary: "Older observation",
      source: "database test",
      observed_at: new Date(observationBase - 1_000).toISOString(),
      confidence: 1,
      valid_for_hours: 1,
    });
    database.recordObservation(db, {
      system_id: "unifi",
      kind: "database_latest_test",
      status: "ok",
      summary: "Latest observation",
      source: "database test",
      observed_at: new Date(observationBase).toISOString(),
      confidence: 1,
      valid_for_hours: 1,
    });
    database.recordAccessTest(db, {
      profile_id: "home-assistant-api-admin",
      result: "verified",
      evidence: "Temporary database access-test update passed",
      source: "database test",
      valid_for_hours: 1,
    });
    database.synchronizeKnowledgeBase(db);
    const accessAfterSync = db.prepare("SELECT test_result FROM access_profiles WHERE id = ?").get("home-assistant-api-admin");
    if (accessAfterSync.test_result !== "verified") throw new Error("Newer access-test state was overwritten by inventory synchronization");
    const appliedChange = database.recordChange(db, {
      system_id: "proxmox",
      summary: "Structured change test",
      before_state: "Test not recorded",
      after_state: "Test recorded",
      verification: "Database row exists",
      rollback: "Temporary database is removed",
      result: "succeeded",
    });
    const incident = database.recordIncident(db, {
      system_id: "reverse_proxy",
      title: "Calendar reverse proxy returned 502",
      severity: "medium",
      status: "open",
      symptoms: "Calendar requests returned HTTP 502",
      source: "database test",
    });
    database.recordIncident(db, {
      id: incident.id,
      system_id: "reverse_proxy",
      title: "Calendar reverse proxy returned 502",
      severity: "medium",
      status: "resolved",
      symptoms: "Calendar requests returned HTTP 502",
      root_cause: "Proxy locations used the wrong guest ports",
      remediation: "Point the locations to the verified guest endpoints",
      prevention: "Verify guest service topology before proxy changes",
      event_summary: "Correct endpoints verified and incident resolved",
      source: "database test",
    });
    database.recordDecision(db, {
      id: "database-test-local-only",
      system_id: "admin_workstation",
      title: "Keep deployment data outside the source tree",
      context: "The public source tree must remain site-neutral",
      decision: "Store deployment data in the private site overlay",
      rationale: "A separate overlay prevents accidental publication",
      alternatives: "Editing tracked example inventory was rejected",
      status: "active",
      source: "database test",
    });
    const learning = database.proposeLearningCandidate(db, {
      system_id: "admin_workstation",
      candidate_type: "runbook",
      title: "Reuse a verified database test procedure",
      trigger: "A complex test required a reusable multi-step procedure",
      proposed_change: "Add the verified procedure to a runbook after review",
      evidence: "The temporary database test completed successfully",
      validation_plan: "Repeat the database test and review the exact runbook diff",
      source: "database test",
    });
    const prematureLearning = database.proposeLearningCandidate(db, {
      system_id: "admin_workstation",
      candidate_type: "policy",
      title: "Premature learning transition test",
      trigger: "A transition guard needs verification",
      proposed_change: "Do not apply this candidate before approval",
      evidence: "Temporary database test evidence",
      validation_plan: "Confirm that direct application is rejected",
      source: "database test",
    });
    let rejectedPrematureApply = false;
    try {
      database.reviewLearningCandidate(db, {
        id: prematureLearning.id,
        action: "apply",
        review_reference: "database negative-path test",
        validation: "Application must be rejected before approval",
        applied_change_id: appliedChange.id,
      });
    } catch {
      rejectedPrematureApply = true;
    }
    if (!rejectedPrematureApply) throw new Error("Learning candidate applied without approval");

    const failedChange = database.recordChange(db, {
      system_id: "admin_workstation",
      summary: "Failed change reference test",
      before_state: "Temporary test baseline",
      after_state: "Temporary test failure",
      verification: "The test change is intentionally failed",
      rollback: "Temporary database is removed",
      result: "failed",
    });
    database.reviewLearningCandidate(db, {
      id: prematureLearning.id,
      action: "approve",
      review_reference: "database negative-path approval",
      validation: "Only the failed-change reference remains to be rejected",
    });
    let rejectedFailedChange = false;
    try {
      database.reviewLearningCandidate(db, {
        id: prematureLearning.id,
        action: "apply",
        review_reference: "database failed-change test",
        validation: "A failed change must not satisfy application",
        applied_change_id: failedChange.id,
      });
    } catch {
      rejectedFailedChange = true;
    }
    if (!rejectedFailedChange) throw new Error("Learning candidate accepted a failed change record");
    database.reviewLearningCandidate(db, {
      id: learning.id,
      action: "approve",
      review_reference: "database test review",
      validation: "The proposed procedure is secret-free and reproducible",
    });
    database.reviewLearningCandidate(db, {
      id: learning.id,
      action: "apply",
      review_reference: "database test apply",
      validation: "The succeeded change record verifies the applied test change",
      applied_change_id: appliedChange.id,
    });
    const primaryThreadId = "01a00157-986f-7853-a626-74106d0e5b78";
    const secondaryThreadId = "01a01049-20d8-7513-a675-d06386a6cbc0";
    const contract = database.createTaskContract(db, {
      objective: "Verify the extended knowledge database",
      success_criteria: ["Schema migration succeeds", "Lifecycle events remain queryable"],
      current_step: "Run database checks",
      source: "database test",
    }, primaryThreadId);
    let rejectedDuplicateContract = false;
    try {
      database.createTaskContract(db, {
        objective: "A second open contract must be rejected",
        success_criteria: ["Only one open contract exists per task"],
        source: "database test",
      }, primaryThreadId);
    } catch {
      rejectedDuplicateContract = true;
    }
    if (!rejectedDuplicateContract) throw new Error("A second open completion contract was accepted");
    let rejectedUnverifiedCompletion = false;
    try {
      database.updateTaskContract(db, {
        id: contract.id,
        status: "completed",
        current_step: "Attempt unverified completion",
        source: "database test",
      }, primaryThreadId);
    } catch {
      rejectedUnverifiedCompletion = true;
    }
    if (!rejectedUnverifiedCompletion) throw new Error("Completion contract accepted completion without verification");
    database.updateTaskContract(db, {
      id: contract.id,
      status: "waiting",
      current_step: "Wait for the bounded test result",
      wait_reason: "The test process is still running",
      wait_job_id: "test-job-id",
      source: "database test",
    }, primaryThreadId);
    database.updateTaskContract(db, {
      id: contract.id,
      status: "active",
      current_step: "Inspect the completed test",
      source: "database test",
    }, primaryThreadId);
    database.updateTaskContract(db, {
      id: contract.id,
      status: "completed",
      current_step: "Complete",
      verification: "All extended database checks passed",
      source: "database test",
    }, primaryThreadId);
    let rejectedTerminalUpdate = false;
    try {
      database.updateTaskContract(db, {
        id: contract.id,
        status: "active",
        current_step: "Attempt to reopen a completed contract",
        source: "database test",
      }, primaryThreadId);
    } catch {
      rejectedTerminalUpdate = true;
    }
    if (!rejectedTerminalUpdate) throw new Error("Completed contract accepted a later update");
    const waitingContract = database.createTaskContract(db, {
      objective: "Verify that resumed agents receive waiting contracts",
      success_criteria: ["Bootstrap exposes the open contract"],
      current_step: "Wait for deterministic evidence",
      source: "database test",
    }, secondaryThreadId);
    let rejectedForeignContractUpdate = false;
    try {
      database.updateTaskContract(db, {
        id: waitingContract.id,
        status: "active",
        current_step: "Foreign update must fail",
        source: "database test",
      }, primaryThreadId);
    } catch {
      rejectedForeignContractUpdate = true;
    }
    if (!rejectedForeignContractUpdate) throw new Error("A foreign task updated another task's completion contract");
    database.updateTaskContract(db, {
      id: waitingContract.id,
      status: "waiting",
      current_step: "Wait for deterministic evidence",
      wait_reason: "Temporary lifecycle verification",
      wait_job_id: "temporary-wait-job",
      source: "database test",
    }, secondaryThreadId);
    db.prepare("UPDATE learning_candidates SET review_due_at=? WHERE id=?")
      .run(new Date(Date.now() - 86_400_000).toISOString(), prematureLearning.id);
    const dueCandidates = database.listLearningCandidates(db, ["approved"]);
    if (!dueCandidates.candidates.some((item) => item.id === prematureLearning.id && item.overdue === true && item.days_remaining <= 0)) {
      throw new Error("Learning candidate review deadline is not exposed");
    }
    database.upsertMaintenance(db, {
      id: "database-test-maintenance",
      system_id: "admin_workstation",
      category: "test",
      title: "Database maintenance test",
      status: "completed",
      verification: "Database row exists",
      source: "database test",
    });

    let rejectedSecret = false;
    try {
      database.recordFact(db, {
        system_id: "proxmox",
        category: "test",
        fact_key: "unsafe_test",
        fact_value: ["-----BEGIN ", "PRIVATE KEY-----"].join(""),
        source: "database test",
        confidence: 1,
      });
    } catch {
      rejectedSecret = true;
    }
    if (!rejectedSecret) throw new Error("Secret-material guard did not reject unsafe input");

    let rejectedIncidentSecret = false;
    try {
      database.recordIncident(db, {
        system_id: "proxmox",
        title: "Unsafe incident test",
        severity: "low",
        status: "open",
        symptoms: "password=not-allowed-here",
        source: "database test",
      });
    } catch {
      rejectedIncidentSecret = true;
    }
    if (!rejectedIncidentSecret) throw new Error("Incident secret-material guard did not reject unsafe input");

    const expiredBase = Date.now() - 7_200_000;
    database.recordObservation(db, {
      system_id: "proxmox",
      kind: "freshness_latest_only_test",
      status: "warning",
      summary: "Expired historical observation",
      source: "database test",
      observed_at: new Date(expiredBase).toISOString(),
      confidence: 1,
      valid_for_hours: 1,
    });
    database.recordObservation(db, {
      system_id: "proxmox",
      kind: "freshness_latest_only_test",
      status: "ok",
      summary: "Current replacement observation",
      source: "database test",
      confidence: 1,
      valid_for_hours: 1,
    });
    const freshness = database.freshnessReport(db);
    if (freshness.expired_observations.some((item) => item.kind === "freshness_latest_only_test")) {
      throw new Error("Freshness report counted an expired historical observation after a current replacement");
    }

    const context = database.contextBootstrap(db);
    if (!Array.isArray(context.systems) || context.systems.length < minimumSyntheticSystems) throw new Error("Bootstrap context is incomplete");
    if (context.detail !== "compact" || context.counts.services < minimumSyntheticServices) {
      throw new Error("Compact bootstrap service summary is incomplete");
    }
    if ("service_catalog" in context || "access_profiles" in context || "verified_capabilities" in context) {
      throw new Error("Compact bootstrap loaded full catalog payloads");
    }
    if (!context.open_learning_candidates.some((item) => item.id === prematureLearning.id && item.status === "approved")) {
      throw new Error("Bootstrap does not expose an approved learning candidate");
    }
    if (!context.learning_attention.some((item) => item.id === prematureLearning.id && item.overdue === true)) {
      throw new Error("Bootstrap does not surface overdue learning review attention");
    }
    if (!context.active_task_contracts.some((item) => item.id === waitingContract.id && item.status === "waiting")) {
      throw new Error("Bootstrap does not expose a waiting completion contract");
    }
    if (context.active_task_contracts.some((item) => item.id === contract.id)) {
      throw new Error("Bootstrap incorrectly exposes a completed contract as active");
    }
    if (JSON.stringify(context).includes("target_thread_id") || JSON.stringify(context).includes("01a01049-20d8-7513-a675-d06386a6cbc0")) {
      throw new Error("Compact bootstrap exposes a private task identifier");
    }
    if (Buffer.byteLength(JSON.stringify(context), "utf8") > 64 * 1024) {
      throw new Error("Compact bootstrap exceeds the 64 KiB payload budget");
    }
    const fullContext = database.contextBootstrap(db, { detail: "full" });
    if (!Array.isArray(fullContext.service_catalog) || fullContext.service_catalog.length < minimumSyntheticServices) {
      throw new Error("Full bootstrap service catalogue is incomplete");
    }
    if (fullContext.systems.some((item) => "overdue" in item || "days_remaining" in item)) {
      throw new Error("Full bootstrap polluted system rows with learning-candidate deadline fields");
    }
    const homeAssistantContext = database.getSystemContext(db, "home_assistant");
    if (!Array.isArray(homeAssistantContext.services) || homeAssistantContext.services.length < 1) {
      throw new Error("System context does not include services");
    }
    const batchContext = database.getSystemContextBatch(db, ["home_assistant", "reverse_proxy"]);
    if (!Array.isArray(batchContext.systems) || batchContext.systems.length !== 2) {
      throw new Error("Batch system context is incomplete");
    }
    const learningSearch = database.searchKnowledge(db, "reusable multi-step procedure", 5);
    if (!learningSearch.learning_candidates.some((item) => item.id === learning.id)) {
      throw new Error("Learning candidate is not searchable");
    }
    const contracts = database.getTaskContracts(db, "01a00157-986f-7853-a626-74106d0e5b78", true);
    if (contracts.contracts.length !== 1 || contracts.contracts[0].events.length !== 4) {
      throw new Error("Completion-contract lifecycle is incomplete");
    }
    if (JSON.stringify(contracts).includes("target_thread_id") || JSON.stringify(contracts).includes("01a00157-986f-7853-a626-74106d0e5b78")) {
      throw new Error("Completion-contract query exposes a private task identifier");
    }
    const unifiContext = database.getSystemContext(db, "unifi");
    const latestObservations = unifiContext.current_observations.filter((item) => item.kind === "database_latest_test");
    if (latestObservations.length !== 1 || latestObservations[0].status !== "ok") {
      throw new Error("System context did not select the latest active observation per kind");
    }
    const search = database.searchKnowledge(db, "Home Assistant", 5);
    if (!Array.isArray(search.knowledge) || search.knowledge.length === 0) throw new Error("Knowledge search returned no results");
    const solutionSearch = database.searchKnowledge(db, "Calendar proxy ports", 5);
    if (!solutionSearch.incidents.some((item) => item.id === incident.id)) {
      throw new Error("Knowledge search did not return the reusable incident resolution");
    }
    const incidentSearch = database.searchIncidents(db, "wrong guest ports", 5);
    if (incidentSearch.incidents.length !== 1 || incidentSearch.incidents[0].events.length !== 2) {
      throw new Error("Incident lifecycle search is incomplete");
    }
    const reverseProxyContext = database.getSystemContext(db, "reverse_proxy");
    if (!reverseProxyContext.incidents.some((item) => item.id === incident.id)) {
      throw new Error("System context does not include incident history");
    }
    if (database.databaseStatistics(db).schema_version !== 4) throw new Error("Schema migration version 4 was not applied");
    const integrity = database.integrityReport(db);
    if (!integrity.ok) throw new Error("SQLite integrity check failed");
    console.log(JSON.stringify({ ok: true, rejected_secret_material: true, incident_lifecycle: true, statistics: integrity.statistics }, null, 2));
  } finally {
    db.close();
  }
} finally {
  if (previousLocalAppData === undefined) delete process.env.LOCALAPPDATA;
  else process.env.LOCALAPPDATA = previousLocalAppData;
  const resolved = path.resolve(temporaryRoot);
  if (!resolved.startsWith(path.resolve(os.tmpdir()) + path.sep)) {
    throw new Error("Refusing to remove a test directory outside the system temporary directory");
  }
  rmSync(resolved, { recursive: true, force: true });
}
