# Homelab subagent policy

## Purpose

Subagents are a latency and context-isolation tool, not the default executor and
not a guaranteed token-saving mechanism. Each subagent performs separate model and
tool work. Use deterministic scripts and the Homelab Job Engine for safe repeatable
work, and reserve subagents for independent work that benefits from parallelism.

The binding operating rules are in `AGENTS.md`. Project-scoped Codex configuration
is in `.codex/config.toml`, with custom roles under `.codex/agents/`.

Official Codex reference:
<https://developers.openai.com/codex/subagents>

## Routing

| Work shape | Executor |
| --- | --- |
| One ordered task or a few tool calls | Primary agent |
| Safe deterministic recurring work | Script or Homelab Job Engine |
| Two independent read-heavy evidence lanes | Up to two subagents |
| Infrastructure or persistent workspace change | Primary agent |
| Credentials, MFA, permissions, network control, destructive work, or daily-review remediation | Primary agent with the existing confirmation boundary |

## Project roles

### `homelab_observer`

Use for one bounded, read-only inventory, health, configuration, log, certificate,
or reachability question. It may use approved runtime credential references but
must not handle or return secret values. Its result is evidence for the primary
agent, not authorization to act.

### `workspace_tester`

Use for one known non-mutating syntax, lint, type, integrity, or regression check.
It stops when a check requires persistent writes, dependency installation, service
changes, or infrastructure access outside the delegated scope.

## Delegation contract

Every delegated task must include:

1. Exact question and bounded scope.
2. Target name and stable identifier when a Homelab system is involved.
3. Relevant secret-free context and the parent bootstrap timestamp.
4. Allowed tools or evidence sources.
5. Required result format and stopping condition.

The primary agent waits for the assigned agents, checks their claims against the
authoritative source order, and alone performs any change, rollback, verification,
knowledge write, or user-facing conclusion.

## Limits and rollback

- Project concurrency is capped at two spawned threads.
- The default subagent model is `gpt-5.6-luna` with low reasoning effort; the
  observer raises effort to medium for evidence correlation.
- The read-only sandbox is a defense-in-depth default. Codex can reapply a live
  parent permission override to a child, so the non-mutation rules in `AGENTS.md`
  and each custom agent's instructions remain binding in every permission mode.
- Nested delegation and parallel shared-state writes are prohibited.
- Remove `.codex/config.toml`, `.codex/agents/`, this runbook, and the matching
  `AGENTS.md` section to roll back the policy.
