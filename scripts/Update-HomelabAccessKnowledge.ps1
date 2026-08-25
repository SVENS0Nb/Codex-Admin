[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$cli = (Resolve-Path (Join-Path $PSScriptRoot '..\mcp\homelab-admin\build\cli.js')).Path
$access = & (Join-Path $PSScriptRoot 'Test-HomelabAdminAccess.ps1')
$mapping = [ordered]@{
    ProxmoxApi = 'proxmox-api-admin'
    HomeAssistantApi = 'home-assistant-api-admin'
    HomeAssistantAppSsh = 'home-assistant-app-ssh'
    HomeAssistantHostSsh = 'home-assistant-haos-ssh'
    ReverseProxySsh = 'reverse-proxy-ssh-admin'
    UniFiApi = 'unifi-api-admin'
    UniFiSsh = 'unifi-console-ssh'
}

$updated = foreach ($property in $mapping.GetEnumerator()) {
    $passed = [bool]$access.($property.Key)
    $record = [ordered]@{
        profile_id = $property.Value
        result = if ($passed) { 'verified' } else { 'failed' }
        evidence = "Secret-safe consolidated access check $($property.Key) returned $passed."
        source = 'scripts/Test-HomelabAdminAccess.ps1'
        valid_for_hours = 168
    }
    $json = $record | ConvertTo-Json -Compress
    $result = $json | & node.exe $cli record-access-test | ConvertFrom-Json
    $json = $null
    $record = $null
    [pscustomobject]@{
        Check = $property.Key
        ProfileId = $property.Value
        Passed = $passed
        Recorded = [bool]$result.ok
    }
}

[pscustomobject]@{
    Success = -not (@($updated | Where-Object { -not $_.Passed -or -not $_.Recorded }).Count -gt 0)
    Results = @($updated)
}
