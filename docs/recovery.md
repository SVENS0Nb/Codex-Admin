# Recovery

## Break-glass requirements

- Maintain at least one human-controlled hypervisor or console credential
  outside the Codex admin VM.
- Maintain gateway console access that does not depend on the normal managed
  network path.
- Keep MFA recovery codes and root credentials outside the Codex admin VM.
- Treat the default local backup directory as the same failure domain as the
  VM. Off-host recovery requires an independently designed encrypted copy.

## Before critical changes

Record the stable target, verified baseline, backup or export, verification,
rollback, and expected management path. Do not modify the only management path
without an independent recovery method and the exact reachability confirmation.

## Control-plane recovery points

`config/control-plane-manifest.json` describes:

1. reviewed Git history as a bundle;
2. the secret-free knowledge database through SQLite online backup;
3. the secret-free Job Engine database through SQLite online backup;
4. the Homelab skill and global agent policy;
5. a credential-free MCP configuration fragment;
6. optionally, a byte-for-byte copy of DPAPI-encrypted Secret UI files.

Create a recovery point only from a clean, reviewed commit:

```powershell
.\scripts\Backup-HomelabControlPlane.ps1
```

The encrypted vault is excluded by default. A copied DPAPI record remains tied
to the same Windows identity and is not portable secret recovery.

The default root is
`%LOCALAPPDATA%\CodexAdmin\control-plane\backups`. Runs never overwrite or
automatically delete an older point. The verification scripts restore Git and
SQLite into isolated temporary locations, validate hashes and schemas, inspect
the skill, policy, and MCP fragment, and never replace live state.

## Restore order

1. Verify the selected recovery point.
2. Clone the Git bundle to staging and run the complete offline quality gate.
3. Stop database consumers before replacing a database; obtain confirmation for
   any service interruption or reachability impact.
4. Restore and integrity-check the knowledge database, followed by the Job
   Engine database.
5. Compare and restore the skill, policy, and MCP fragment.
6. Restore encrypted vault files only under the same Windows identity and verify
   access without displaying values.
7. Run offline and live health checks and record the recovery.

Never overwrite the only working copy, copy a live WAL file as a backup, or
treat a successful file copy as database verification.
