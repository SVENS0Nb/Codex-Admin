[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Command
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'CodexAdmin.Common.psm1') -Force
$store = (Resolve-Path (Join-Path $repositoryRoot 'apps\secret-ui\backend\SecretUiStore.ps1')).Path
$helper = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-SshCommand.py')).Path
$knownHosts = Join-Path $env:USERPROFILE '.ssh\known_hosts'

$profiles = Get-Content -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\access-profiles.json') -Raw |
    ConvertFrom-Json
$profile = $profiles.profiles | Where-Object id -eq 'qnap-ssh-admin' | Select-Object -First 1
if (-not $profile -or [string]::IsNullOrWhiteSpace([string]$profile.credential_ref)) {
    throw 'The QNAP administrative access profile is incomplete.'
}

$interfaces = Get-Content -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\interfaces.json') -Raw |
    ConvertFrom-Json
$interface = $interfaces.interfaces | Where-Object id -eq 'qnap-ssh' | Select-Object -First 1
if (-not $interface -or -not $interface.address -or -not $interface.port -or -not $interface.username) {
    throw 'The QNAP SSH interface is incomplete.'
}

$password = $null
try {
    & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $store `
        -Action Copy -Id ([string]$profile.credential_ref) -ClearAfterSeconds 5 | Out-Null
    $password = (Get-Clipboard -Raw).TrimEnd("`r", "`n")
    Set-Clipboard -Value ''
    if ([string]::IsNullOrWhiteSpace($password)) {
        throw 'The QNAP vault value is unavailable.'
    }

    $password | & python.exe $helper `
        --host ([string]$interface.address) `
        --port ([int]$interface.port) `
        --user ([string]$interface.username) `
        --known-hosts $knownHosts `
        --password-stdin `
        --sudo-password-stdin `
        --command $Command
    $exitCode = $LASTEXITCODE
    $password = $null
    if ($exitCode -ne 0) {
        throw "QNAP root command failed with exit code $exitCode."
    }
}
finally {
    Set-Clipboard -Value ''
    $password = $null
}
