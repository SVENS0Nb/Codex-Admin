[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolvedBackup = (Resolve-Path -LiteralPath $BackupPath).Path
$approvedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexAdmin\control-plane\backups'))
if (-not $resolvedBackup.StartsWith($approvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Control-plane backup path is outside the approved local backup root.'
}

$manifestPath = Join-Path $resolvedBackup 'backup-manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 2) { throw 'Unsupported control-plane backup manifest schema.' }
$fileResults = foreach ($file in @($manifest.files)) {
    $relative = [string]$file.relative_path
    $target = [IO.Path]::GetFullPath((Join-Path $resolvedBackup $relative))
    $inside = $target.StartsWith($resolvedBackup + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    $ok = $inside -and (Test-Path -LiteralPath $target -PathType Leaf) -and
        (Get-Item -LiteralPath $target).Length -eq [int64]$file.bytes -and
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq [string]$file.sha256
    [pscustomobject]@{ relative_path = $relative; ok = $ok }
}

$knowledgePath = Join-Path $resolvedBackup 'databases\homelab-ops.sqlite3'
$knowledgeIntegrity = & node.exe (Join-Path $repositoryRoot 'mcp\homelab-admin\build\cli.js') integrity-file $knowledgePath 2>$null
$knowledgeOk = $LASTEXITCODE -eq 0 -and ($knowledgeIntegrity | ConvertFrom-Json).ok
$jobPath = Join-Path $resolvedBackup 'databases\jobs.sqlite3'
$jobIntegrity = & node.exe (Join-Path $repositoryRoot 'apps\job-engine\backup.mjs') verify $jobPath 2>$null
$jobOk = $LASTEXITCODE -eq 0 -and ($jobIntegrity | ConvertFrom-Json).ok
$bundlePath = Join-Path $resolvedBackup 'repository\homelab-ops.bundle'
& git bundle verify $bundlePath *> $null
$bundleOk = $LASTEXITCODE -eq 0
$agentRestore = & (Join-Path $PSScriptRoot 'Test-HomelabControlPlaneAgentRestore.ps1') -BackupPath $resolvedBackup

$failedFiles = @($fileResults | Where-Object { -not $_.ok })
$result = [pscustomobject]@{
    success = $failedFiles.Count -eq 0 -and $knowledgeOk -and $jobOk -and $bundleOk -and [bool]$agentRestore.success
    file_count = @($fileResults).Count
    file_hashes_ok = $failedFiles.Count -eq 0
    knowledge_database_ok = [bool]$knowledgeOk
    job_engine_database_ok = [bool]$jobOk
    git_bundle_ok = [bool]$bundleOk
    isolated_agent_restore_ok = [bool]$agentRestore.success
    agent_restore = $agentRestore
    encrypted_secret_vault_included = [bool]$manifest.encrypted_secret_vault.included
    accepted_constraints = @($manifest.accepted_constraints)
}
$result
