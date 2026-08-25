[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$collector = (Resolve-Path (Join-Path $repoRoot 'apps\unifi-security-log\unifi-security-log.mjs')).Path
$node = (Get-Command node.exe -ErrorAction Stop).Source

& $node $collector sync
if ($LASTEXITCODE -ne 0) {
    throw "UniFi security log collection failed with exit code $LASTEXITCODE."
}
