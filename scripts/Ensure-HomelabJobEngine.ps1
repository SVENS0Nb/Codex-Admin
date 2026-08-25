[CmdletBinding()]
param(
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'CodexAdmin\job-engine'),

    [string]$NodePath = (Get-Command node.exe -ErrorAction Stop).Source,

    [ValidateRange(1, 60)]
    [int]$StartupTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$healthUrl = 'http://127.0.0.1:8770/healthz'
$appRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\apps\job-engine')).Path
$sdkManifest = Join-Path $appRoot 'node_modules\@openai\codex-sdk\package.json'

function Get-JobEngineHealth {
    try {
        $response = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
        if ($response.ok -and $response.scheduler.running) { return $response }
    }
    catch {}
    return $null
}

$health = Get-JobEngineHealth
if ($health) {
    [pscustomobject]@{
        State = 'AlreadyRunning'
        Url = 'http://127.0.0.1:8770/'
        RuntimeIdentity = [string]$health.scheduler.execution_identity
    }
    return
}

if (-not (Test-Path -LiteralPath $sdkManifest -PathType Leaf)) {
    $npmPath = (Get-Command npm.cmd -ErrorAction Stop).Source
    & $npmPath ci --omit=dev --no-audit --no-fund --prefix $appRoot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $sdkManifest -PathType Leaf)) {
        throw 'The pinned Codex SDK dependency could not be restored for the Job Engine.'
    }
}

$runnerPath = (Resolve-Path (Join-Path $PSScriptRoot 'Start-HomelabJobEngineService.ps1')).Path
$nodePath = (Resolve-Path -LiteralPath $NodePath).Path
$dataRoot = [IO.Path]::GetFullPath($DataRoot)
if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    throw "Job Engine data directory was not found at $dataRoot"
}

$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "{0}" -NodePath "{1}" -DataRoot "{2}"' -f $runnerPath, $nodePath, $dataRoot
Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null

$deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
do {
    Start-Sleep -Milliseconds 500
    $health = Get-JobEngineHealth
} until ($health -or (Get-Date) -ge $deadline)

if (-not $health) {
    throw "The Job Engine did not become healthy within $StartupTimeoutSeconds seconds."
}

[pscustomobject]@{
    State = 'Started'
    Url = 'http://127.0.0.1:8770/'
    RuntimeIdentity = [string]$health.scheduler.execution_identity
}
