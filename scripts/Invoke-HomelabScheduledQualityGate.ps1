[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$statusRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab\quality'
$statusPath = Join-Path $statusRoot 'latest.json'
$temporaryPath = Join-Path $statusRoot ("latest.{0}.tmp" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null

function Write-QualityStatus {
    param([Parameter(Mandatory)][Collections.IDictionary]$Status)
    [IO.File]::WriteAllText($temporaryPath, ($Status | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $statusPath -Force
}

try {
    $qualityScript = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-HomelabProjectQualityGate.ps1')).Path
    $quality = & $qualityScript -NoFail
    $status = [ordered]@{
        schema_version = 1
        generated_at = [DateTimeOffset]::Now.ToString('o')
        success = [bool]$quality.success
        total = [int]$quality.total
        passed = [int]$quality.passed
        failed = [int]$quality.failed
        failed_steps = @($quality.results | Where-Object { -not $_.passed } | ForEach-Object { [string]$_.name })
    }
    Write-QualityStatus -Status $status
    [pscustomobject]$status
    if (-not $status.success) { exit 1 }
}
catch {
    $reason = [string]$_.Exception.Message
    $reason = $reason -replace '(?i)\b(Bearer|token|password|secret|authorization)\s*[:=]\s*\S+', '$1=[REDACTED]'
    if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 300) }
    Write-QualityStatus -Status ([ordered]@{
        schema_version = 1
        generated_at = [DateTimeOffset]::Now.ToString('o')
        success = $false
        total = 0
        passed = 0
        failed = 1
        failed_steps = @('quality_gate_execution')
        failure_reason = $reason
    })
    throw
}
finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
