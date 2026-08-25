[CmdletBinding()]
param(
    [string]$NodePath,

    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$appRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\apps\job-engine')).Path
$serverPath = Join-Path $appRoot 'server.mjs'
$sdkManifest = Join-Path $appRoot 'node_modules\@openai\codex-sdk\package.json'
$NodePath = if ($NodePath) { (Resolve-Path -LiteralPath $NodePath).Path } else { (Get-Command node.exe -ErrorAction Stop).Source }
$DataRoot = if ($DataRoot) { [IO.Path]::GetFullPath($DataRoot) } else { Join-Path $env:LOCALAPPDATA 'CodexAdmin\job-engine' }

if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    throw "Job Engine server was not found at $serverPath"
}
if (-not (Test-Path -LiteralPath $sdkManifest -PathType Leaf)) {
    throw "Pinned Codex SDK dependency was not found at $sdkManifest"
}
if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
    throw "Node executable was not found at $NodePath"
}
if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
    throw "Job Engine data directory was not found at $DataRoot"
}

$env:HOMELAB_JOB_ENGINE_PORT = '8770'
$env:HOMELAB_JOB_ENGINE_DATA = $DataRoot
Set-Location -LiteralPath $appRoot

while ($true) {
    try {
        & $NodePath $serverPath
        $delaySeconds = if ($LASTEXITCODE -eq 0) { 2 } else { 10 }
    }
    catch {
        $delaySeconds = 10
    }
    Start-Sleep -Seconds $delaySeconds
}
