# UniFi security logging

The Primary Site Dream Machine keeps IDS/IPS detections in its local
`/var/log/ulog/threat.log`. The dedicated Admin VM pulls only an explicit,
sanitized subset over the existing strict-host-key SSH path and stores it in a
separate SQLite database:

    %LOCALAPPDATA%\CodexAdmin\homelab\unifi-security\unifi-security.sqlite3

The collector is intentionally pull-only. It does not enable NetFlow, change
UniFi traffic-logging settings, add a listener, or open a Windows firewall port.

## Data model and privacy

`security_events` retains the event time, UniFi/Suricata action, category,
severity, signature identity and name, flow identity, source and destination
addresses and ports, protocol, interface names, and selected UniFi
classification fields. `collection_runs` records sanitized collection health.
`metadata` holds the source cursor and schema information.

Raw JSON, HTTP metadata, headers, URLs, user agents, cookies, request bodies,
packet payloads, MAC addresses, credentials, and authorization data are never
stored. Event rows are SHA-256 deduplicated, and the SSH source cursor handles
normal log rotation. No automatic event deletion is configured.

## Agent use

Synchronize interactively:

    .\scripts\Sync-UniFiSecurityLog.ps1

Read database status or recent events:

    .\scripts\Get-UniFiSecurityEvents.ps1 -Status
    .\scripts\Get-UniFiSecurityEvents.ps1 -Hours 24 -Limit 100
    .\scripts\Get-UniFiSecurityEvents.ps1 -Hours 168 -Action blocked
    .\scripts\Get-UniFiSecurityEvents.ps1 -Hours 168 -SignatureId 2029054

The enabled recurring Job Engine entry `UniFi security event archive` runs the
sync every minute. It is safe for unattended execution because it performs only
strict SSH reads and local append/deduplication. It must never be extended to
change an IPS rule, acknowledge a detection, or reconfigure UniFi.

Create or repair the idempotent Job Engine registration with:

    .\scripts\Register-UniFiSecurityLogJob.ps1

For complete traffic-flow export or CEF/SIEM activity logging, use the official
UniFi export settings. Those alternatives require a receiving listener and a
firewall/configuration change and therefore remain outside this pull-only
collector until separately approved.
