[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$secretRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\secrets'
if (-not (Test-Path -LiteralPath $secretRoot)) {
    Write-Output 'No DPAPI secrets have been stored.'
    return
}

Get-ChildItem -LiteralPath $secretRoot -Filter '*.secret' -File | ForEach-Object {
    $valid = $false
    try {
        $null = Get-Content -LiteralPath $_.FullName -Raw | ConvertTo-SecureString
        $valid = $true
    } catch {
        $valid = $false
    }
    [pscustomobject]@{
        name = $_.BaseName
        decryptable_by_current_user = $valid
        modified = $_.LastWriteTime
    }
}
