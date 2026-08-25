import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

const serverPath = new URL("../build/index.js", import.meta.url).pathname.replace(/^\/(.:)/, "$1");
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [serverPath],
  env: { ...process.env, CODEX_THREAD_ID: "01a00157-986f-7853-a626-74106d0e5b78" },
});
const client = new Client({ name: "homelab-admin-smoke", version: "0.1.0" });

await client.connect(transport);
try {
  const listed = await client.listTools();
  const names = listed.tools.map((tool) => tool.name).sort();
  const required = [
    "access_test_record",
    "admin_policy_get",
    "change_record",
    "context_bootstrap",
    "fact_record",
    "inventory_get",
    "knowledge_freshness_report",
    "knowledge_search",
    "knowledge_statistics",
    "learning_candidate_list",
    "learning_candidate_propose",
    "learning_candidate_review",
    "maintenance_upsert",
    "observation_record",
    "service_tcp_check",
    "service_read_batch",
    "service_tls_certificate",
    "system_context_batch_get",
    "system_context_get",
    "task_contract_create",
    "task_contract_get",
    "task_contract_update",
  ];
  for (const name of required) {
    if (!names.includes(name)) throw new Error(`Missing MCP tool: ${name}`);
  }
  const context = await client.callTool({
    name: "context_bootstrap",
    arguments: {},
  });
  const system = await client.callTool({
    name: "system_context_get",
    arguments: { system_id: "home_assistant" },
  });
  const systemBatch = await client.callTool({
    name: "system_context_batch_get",
    arguments: { system_ids: ["home_assistant", "reverse_proxy"] },
  });
  const learningCandidates = await client.callTool({
    name: "learning_candidate_list",
    arguments: { statuses: ["proposed", "approved"] },
  });
  const taskContracts = await client.callTool({
    name: "task_contract_get",
    arguments: { include_finished: false },
  });
  const foreignTaskContractQuery = await client.callTool({
    name: "task_contract_get",
    arguments: {
      target_thread_id: "01a01049-20d8-7513-a675-d06386a6cbc0",
      include_finished: false,
    },
  });
  if (!foreignTaskContractQuery.isError) {
    throw new Error("Task contract tool accepted a caller-selected foreign thread identifier");
  }
  const knowledge = await client.callTool({
    name: "knowledge_search",
    arguments: { query: "Home Assistant", limit: 5 },
  });
  console.log(JSON.stringify({
    tools: names,
    context_loaded: context.content.length > 0,
    system_context_loaded: system.content.length > 0,
    system_context_batch_loaded: systemBatch.content.length > 0,
    learning_candidates_loaded: learningCandidates.content.length > 0,
    task_contracts_loaded: taskContracts.content.length > 0,
    knowledge_search_loaded: knowledge.content.length > 0,
  }, null, 2));
} finally {
  await client.close();
}
