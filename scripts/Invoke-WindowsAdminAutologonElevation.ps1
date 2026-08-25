[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable')]
    [string]$Mode = 'Enable',

    [string]$AccountName
)

$ErrorActionPreference = 'Stop'
$targetScript = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-WindowsAdminAutologonTarget.ps1')).Path
$resultPath = Join-Path $env:TEMP 'codex-admin-autologon-result.json'
$errorPath = Join-Path $env:TEMP 'codex-admin-autologon-error.json'
foreach ($path in @($resultPath, $errorPath)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = @(
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy', 'RemoteSigned',
    '-File', ('"{0}"' -f $targetScript),
    '-Mode', $Mode,
    '-AccountName', ('"{0}"' -f $AccountName),
    '-ResultPath', ('"{0}"' -f $resultPath),
    '-ErrorPath', ('"{0}"' -f $errorPath)
)

$process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments `
    -Verb RunAs -WindowStyle Normal -Wait -PassThru
if ($process.ExitCode -ne 0) {
    if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
        $failure = Get-Content -LiteralPath $errorPath -Raw | ConvertFrom-Json
        $codeText = if ($null -ne $failure.nativeErrorCode) { " (Windows-Fehlercode $($failure.nativeErrorCode))" } else { '' }
        throw "Die erhöhte Einrichtung ist fehlgeschlagen$codeText`: $($failure.message)"
    }
    throw "The elevated autologon configuration exited with code $($process.ExitCode)."
}
if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    throw 'The elevated autologon configuration did not produce a verification result.'
}

$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
if (-not $result.success) {
    throw 'Windows automatic logon was not verified.'
}

$verb = if ($Mode -eq 'Enable') { 'configured' } else { 'disabled' }
Write-Host "Windows automatic logon for $($result.user) was $verb and verified." -ForegroundColor Green
Write-Host 'Press Enter to close this window.'
[void](Read-Host)
