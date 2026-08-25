[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$BackupRetentionCount = 30
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$cli = (Resolve-Path (Join-Path $PSScriptRoot '..\mcp\homelab-admin\build\cli.js')).Path
$knowledgeRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab'
$statusPath = Join-Path $knowledgeRoot 'last-maintenance.json'

if (-not (Test-Path -LiteralPath $knowledgeRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $knowledgeRoot -Force | Out-Null
}

$startedAt = [DateTimeOffset]::Now
$sync = & node.exe $cli sync | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $sync.ok) { throw 'Knowledge synchronization failed.' }

$endpoints = & node.exe $cli check-endpoints | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Endpoint observation update failed.' }

$integrity = & node.exe $cli integrity | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $integrity.ok) { throw 'Knowledge database integrity check failed.' }

$backup = & node.exe $cli backup $BackupRetentionCount | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $backup.ok) { throw 'Knowledge database backup failed.' }

$report = [ordered]@{
    success = $true
    started_at = $startedAt.ToString('o')
    completed_at = [DateTimeOffset]::Now.ToString('o')
    repository_sync = $sync.ok
    endpoints_all_reachable = $endpoints.ok
    database_integrity = $integrity.ok
    backup_created = $true
    backup_retention_target = $BackupRetentionCount
    backup_prune_requires_confirmation = [bool]$backup.prune_requires_confirmation
    backup_prune_candidates = @($backup.prune_candidates).Count
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statusPath -Encoding utf8
[pscustomobject]$report
