[CmdletBinding()]
param(
    [uri]$EngineUri = 'http://127.0.0.1:8770/'
)

& (Join-Path $PSScriptRoot 'Sync-HomelabRecurringJobs.ps1') -EngineUri $EngineUri `
    -Name 'UniFi security event archive' -Apply
