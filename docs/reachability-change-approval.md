# Reachability-change approval

This rule applies to every Homelab system and every internal, external, local,
remote, interactive, automated, user, service, and administrative access path.

## Trigger

Treat a change as confirmation-required when it could temporarily or permanently
reduce, narrow, interrupt, remove, or make less reliable any access path used by
the user. When impact is uncertain, treat the trigger as active.

Examples include listener and port bindings, allowlists, firewall and VLAN policy,
routes, NAT, DNS, certificates and trust, VPNs and tunnels, management addresses or
URLs, accounts, authentication and permissions, service stops or restarts, reboots,
shutdowns, upgrades, maintenance modes, and scheduled or unattended execution.

## Required standalone proposal

Complete read-only discovery and rollback preparation first. Immediately before
the action, present one standalone proposal containing:

1. Exact system and stable target.
2. Verified current access path and who can use it.
3. Exact post-change access path and who will no longer be able to use it.
4. Affected clients, networks, services, protocols, ports, names and dependencies.
5. Why the change is needed and access-preserving alternatives.
6. Expected interruption, duration, lockout and recovery risk.
7. Verified independent management path and exact rollback or recovery procedure.

Wait for an unambiguous user confirmation referring to that exact proposal. Broad
autonomy, generic requests such as "umsetzen" or "beheben", approval of a larger
task, approval of another change, and historical standing permission do not count.

If the target, scope, method, effect, timing, risk, or rollback changes after the
confirmation, stop and request a new confirmation. Never bundle this decision with
unrelated changes.

## Execution boundary

Before confirmation, only read-only diagnosis, backup or rollback verification,
and a non-mutating dry run are permitted. Scheduled and unattended jobs must never
perform a reachability-reducing action. After confirmation, reverify the live state,
make the smallest reversible change, continuously protect the independent access
path, and verify every affected route. Roll back when verification fails.
