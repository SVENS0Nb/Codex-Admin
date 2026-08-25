[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$NoStart,

    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'CodexAdmin\job-engine'),

    [string]$NodePath = (Get-Command node.exe -ErrorAction Stop).Source
)

$ErrorActionPreference = 'Stop'
$taskName = 'CodexAdmin - Codex Desktop Autostart'
$codexInstaller = (Resolve-Path (Join-Path $PSScriptRoot 'Install-CodexDesktopAutostart.ps1')).Path
$codexLauncher = (Resolve-Path (Join-Path $PSScriptRoot 'Start-CodexDesktop.ps1')).Path
$starterPath = (Resolve-Path (Join-Path $PSScriptRoot 'Ensure-HomelabJobEngine.ps1')).Path
$nodePath = (Resolve-Path -LiteralPath $NodePath).Path
$dataRoot = [IO.Path]::GetFullPath($DataRoot)

if ((Get-Content -Raw $codexLauncher) -notmatch 'Ensure-HomelabJobEngine\.ps1') {
    throw 'The Codex logon launcher does not contain the required Job Engine bootstrap.'
}

if (-not $PSCmdlet.ShouldProcess($taskName, 'Install shared Codex and Job Engine logon task')) {
    return
}

& $codexInstaller -NoStart | Out-Null

if (-not $NoStart) {
    & $starterPath -NodePath $nodePath -DataRoot $dataRoot | Out-Null
}

[pscustomobject]@{
    TaskName = $taskName
    State = 'Registered'
    Trigger = 'InteractiveUserLogon'
    JobEngineUrl = 'http://127.0.0.1:8770/'
    DataRoot = $dataRoot
}
