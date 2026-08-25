[CmdletBinding()]
param(
    [string]$InventoryPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'CodexAdmin.Common.psm1') -Force
if ([string]::IsNullOrWhiteSpace($InventoryPath)) {
    $InventoryPath = Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\services.json'
}
$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
$results = foreach ($property in $inventory.services.PSObject.Properties) {
    $name = $property.Name
    $service = $property.Value

    if (-not $service.enabled) {
        [pscustomobject]@{ service = $name; configured = $false; host = $null; port = $service.tcp_port; reachable = $null; detail = 'disabled' }
        continue
    }
    if ([string]::IsNullOrWhiteSpace($service.base_url)) {
        [pscustomobject]@{ service = $name; configured = $false; host = $null; port = $service.tcp_port; reachable = $false; detail = 'base_url is empty' }
        continue
    }

    try {
        $uri = [uri]$service.base_url
        $port = if ($service.tcp_port) { [int]$service.tcp_port } elseif ($uri.Port -gt 0) { $uri.Port } else { 443 }
        $reachable = Test-NetConnection -ComputerName $uri.DnsSafeHost -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
        [pscustomobject]@{ service = $name; configured = $true; host = $uri.DnsSafeHost; port = $port; reachable = $reachable; detail = 'TCP only; no credentials transmitted' }
    } catch {
        [pscustomobject]@{ service = $name; configured = $false; host = $null; port = $service.tcp_port; reachable = $false; detail = $_.Exception.Message }
    }
}

$results
