[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$appRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\apps\secret-ui')).Path
$serverPath = Join-Path $appRoot 'server.mjs'
$nodePath = (Get-Command node.exe -ErrorAction Stop).Source

if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) {
    throw "Secret UI server was not found at $serverPath"
}

$env:HOMELAB_SECRET_UI_NO_OPEN = '1'
$env:HOMELAB_SECRET_UI_SERVICE = '1'
Set-Location -LiteralPath $appRoot

while ($true) {
    try {
        & $nodePath $serverPath
        $delaySeconds = if ($LASTEXITCODE -eq 0) { 2 } else { 10 }
    }
    catch {
        $delaySeconds = 10
    }
    Start-Sleep -Seconds $delaySeconds
}
