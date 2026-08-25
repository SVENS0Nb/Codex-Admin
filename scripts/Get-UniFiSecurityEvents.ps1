[CmdletBinding(DefaultParameterSetName = 'Events')]
param(
    [Parameter(ParameterSetName = 'Events')]
    [ValidateRange(1, 87600)]
    [int]$Hours = 24,

    [Parameter(ParameterSetName = 'Events')]
    [ValidateRange(1, 1000)]
    [int]$Limit = 100,

    [Parameter(ParameterSetName = 'Events')]
    [ValidateSet('blocked', 'allowed')]
    [string]$Action,

    [Parameter(ParameterSetName = 'Events')]
    [ValidateRange(1, 2147483647)]
    [int]$SignatureId,

    [Parameter(Mandatory, ParameterSetName = 'Status')]
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$collector = (Resolve-Path (Join-Path $repoRoot 'apps\unifi-security-log\unifi-security-log.mjs')).Path
$node = (Get-Command node.exe -ErrorAction Stop).Source
$arguments = [System.Collections.Generic.List[string]]::new()
$arguments.Add($collector)

if ($Status) {
    $arguments.Add('status')
} else {
    $arguments.Add('query')
    $arguments.Add('--hours')
    $arguments.Add([string]$Hours)
    $arguments.Add('--limit')
    $arguments.Add([string]$Limit)
    if ($Action) {
        $arguments.Add('--action')
        $arguments.Add($Action)
    }
    if ($PSBoundParameters.ContainsKey('SignatureId')) {
        $arguments.Add('--signature-id')
        $arguments.Add([string]$SignatureId)
    }
}

$json = & $node @arguments
if ($LASTEXITCODE -ne 0) {
    throw "UniFi security database query failed with exit code $LASTEXITCODE."
}
$json | ConvertFrom-Json
