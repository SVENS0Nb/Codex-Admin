[CmdletBinding()]
param(
    [switch]$IncludeEncryptedSecretVault
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$status = @(& git -C $repositoryRoot status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect repository state.' }
if ($status.Count -gt 0) {
    throw 'The repository has uncommitted changes. Create a reviewed local commit before producing a recoverable control-plane bundle.'
}

$backupRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexAdmin\control-plane\backups'))
$stamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
$destination = Join-Path $backupRoot $stamp
New-Item -ItemType Directory -Path $destination -Force | Out-Null

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($principal in @($identity, 'NT AUTHORITY\SYSTEM')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $principal,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
Set-PrivateDirectoryAcl -Path $destination

$databaseRoot = Join-Path $destination 'databases'
$repositoryBackupRoot = Join-Path $destination 'repository'
$codexRoot = Join-Path $destination 'codex'
New-Item -ItemType Directory -Path $databaseRoot, $repositoryBackupRoot, $codexRoot -Force | Out-Null

$knowledgeCli = Join-Path $repositoryRoot 'mcp\homelab-admin\build\cli.js'
$knowledgeBackup = & node.exe $knowledgeCli backup 30 | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $knowledgeBackup.ok) { throw 'Knowledge database online backup failed.' }
Copy-Item -LiteralPath ([string]$knowledgeBackup.destination) -Destination (Join-Path $databaseRoot 'homelab-ops.sqlite3')

$jobBackup = & node.exe (Join-Path $repositoryRoot 'apps\job-engine\backup.mjs') backup | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $jobBackup.ok) { throw 'Job Engine online backup failed.' }
Copy-Item -LiteralPath ([string]$jobBackup.destination) -Destination (Join-Path $databaseRoot 'jobs.sqlite3')

$bundlePath = Join-Path $repositoryBackupRoot 'homelab-ops.bundle'
& git -C $repositoryRoot bundle create $bundlePath --all
if ($LASTEXITCODE -ne 0) { throw 'Git control-plane bundle creation failed.' }

$skillSource = Join-Path $env:USERPROFILE '.codex\skills\homelab-admin'
Copy-Item -LiteralPath $skillSource -Destination (Join-Path $codexRoot 'homelab-admin-skill') -Recurse
$globalAgents = Join-Path $env:USERPROFILE '.codex\AGENTS.md'
Copy-Item -LiteralPath $globalAgents -Destination (Join-Path $codexRoot 'AGENTS.md')
$escapedMcpEntrypoint = (Join-Path $repositoryRoot 'mcp\homelab-admin\build\index.js').Replace('\', '\\')
$mcpConfig = @"
# Generated recovery fragment. It intentionally contains no credentials or environment values.
[mcp_servers.homelab_admin]
command = "node"
args = ["$escapedMcpEntrypoint"]
"@
[IO.File]::WriteAllText((Join-Path $codexRoot 'homelab-admin-mcp.toml'), $mcpConfig, [Text.UTF8Encoding]::new($false))

$vaultSummary = [ordered]@{ included = $false; file_count = 0; aggregate_sha256 = $null }
if ($IncludeEncryptedSecretVault) {
    $vaultSource = Join-Path $env:LOCALAPPDATA 'CodexAdmin\secret-ui'
    $vaultTarget = Join-Path $destination 'encrypted-secret-vault'
    Copy-Item -LiteralPath $vaultSource -Destination $vaultTarget -Recurse
    $vaultHashes = @(Get-ChildItem -LiteralPath $vaultTarget -Recurse -File | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    } | Sort-Object)
    $aggregateText = $vaultHashes -join "`n"
    $aggregateBytes = [Text.Encoding]::UTF8.GetBytes($aggregateText)
    $vaultSummary = [ordered]@{
        included = $true
        file_count = $vaultHashes.Count
        aggregate_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($aggregateBytes)).ToLowerInvariant()
    }
}

$files = @(Get-ChildItem -LiteralPath $destination -Recurse -File | Where-Object {
    $_.FullName -notlike (Join-Path $destination 'encrypted-secret-vault\*') -and $_.Name -ne 'backup-manifest.json'
} | ForEach-Object {
    [ordered]@{
        relative_path = [IO.Path]::GetRelativePath($destination, $_.FullName)
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$manifest = [ordered]@{
    schema_version = 2
    created_at = [DateTimeOffset]::Now.ToString('o')
    source_commit = (& git -C $repositoryRoot rev-parse HEAD).Trim()
    repository_clean = $true
    files = $files
    encrypted_secret_vault = $vaultSummary
    deletion_requires_confirmation = $true
    accepted_constraints = @(
        'The encrypted DPAPI secret vault is excluded unless explicitly requested.',
        'Recovery points remain on the dedicated admin VM and therefore share its failure domain.',
        'Recovery-point deletion is never automatic.',
        'Agent assets are restore-tested only in an isolated temporary directory and never overwrite live Codex paths.'
    )
}
$manifestPath = Join-Path $destination 'backup-manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

$verification = & (Join-Path $PSScriptRoot 'Test-HomelabControlPlaneBackup.ps1') -BackupPath $destination
if (-not $verification.success) { throw 'Control-plane backup restore verification failed.' }
$manifest['restore_verification'] = [ordered]@{
    verified_at = [DateTimeOffset]::Now.ToString('o')
    file_hashes_ok = [bool]$verification.file_hashes_ok
    knowledge_database_ok = [bool]$verification.knowledge_database_ok
    job_engine_database_ok = [bool]$verification.job_engine_database_ok
    git_bundle_ok = [bool]$verification.git_bundle_ok
    isolated_agent_restore_ok = [bool]$verification.isolated_agent_restore_ok
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    success = $true
    backup_path = $destination
    source_commit = $manifest.source_commit
    file_count = $verification.file_count
    encrypted_secret_vault_included = [bool]$vaultSummary.included
    restore_test_passed = $true
    prune_requires_confirmation = $true
    accepted_constraints = @($manifest.accepted_constraints)
}
