[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$backupScript = (Resolve-Path (Join-Path $PSScriptRoot 'Backup-HomelabControlPlane.ps1')).Path
$statusRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\control-plane\status'
$statusPath = Join-Path $statusRoot 'latest.json'
$temporaryPath = Join-Path $statusRoot ("latest.{0}.tmp" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null

function Write-BackupStatus {
    param([Parameter(Mandatory)][Collections.IDictionary]$Status)
    [IO.File]::WriteAllText($temporaryPath, ($Status | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $statusPath -Force
}

try {
    $backup = & $backupScript
    $status = [ordered]@{
        schema_version = 1
        generated_at = [DateTimeOffset]::Now.ToString('o')
        success = [bool]$backup.success
        backup_path = [string]$backup.backup_path
        source_commit = [string]$backup.source_commit
        file_count = [int]$backup.file_count
        encrypted_secret_vault_included = [bool]$backup.encrypted_secret_vault_included
        restore_test_passed = [bool]$backup.restore_test_passed
        prune_requires_confirmation = [bool]$backup.prune_requires_confirmation
        accepted_constraints = @($backup.accepted_constraints)
    }
    Write-BackupStatus -Status $status
    [pscustomobject]$status
    if (-not $status.success -or -not $status.restore_test_passed) { exit 1 }
}
catch {
    $reason = [string]$_.Exception.Message
    $reason = $reason -replace '(?i)\b(Bearer|token|password|secret|authorization)\s*[:=]\s*\S+', '$1=[REDACTED]'
    if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 300) }
    Write-BackupStatus -Status ([ordered]@{
        schema_version = 1
        generated_at = [DateTimeOffset]::Now.ToString('o')
        success = $false
        failure_reason = $reason
        restore_test_passed = $false
        prune_requires_confirmation = $true
    })
    throw
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
