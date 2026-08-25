[CmdletBinding()]
param(
    [ValidateSet('Enable', 'Disable')]
    [string]$Mode = 'Enable',

    [string]$AccountName,

    [Parameter(Mandatory)]
    [string]$ResultPath,

    [Parameter(Mandatory)]
    [string]$ErrorPath
)

$ErrorActionPreference = 'Stop'
$targetScript = (Resolve-Path (Join-Path $PSScriptRoot 'Set-WindowsAdminAutologon.ps1')).Path

try {
    & $targetScript -Mode $Mode -AccountName $AccountName -ResultPath $ResultPath
}
catch {
    $nativeErrorCode = $null
    if ($_.Exception.PSObject.Properties['NativeErrorCode']) {
        $nativeErrorCode = [int]$_.Exception.NativeErrorCode
    }
    elseif ($_.Exception.InnerException -and $_.Exception.InnerException.PSObject.Properties['NativeErrorCode']) {
        $nativeErrorCode = [int]$_.Exception.InnerException.NativeErrorCode
    }

    # This diagnostic intentionally excludes invocation arguments, credentials,
    # environment dumps, and error records that could contain sensitive values.
    [ordered]@{
        success = $false
        exceptionType = $_.Exception.GetType().FullName
        nativeErrorCode = $nativeErrorCode
        message = [string]$_.Exception.Message
        scriptStackTrace = [string]$_.ScriptStackTrace
        occurredAt = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ErrorPath -Encoding utf8
    exit 1
}
