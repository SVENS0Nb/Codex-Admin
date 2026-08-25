[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{1,63}$')]
    [string]$Name,

    [ValidateRange(5, 300)]
    [int]$ClearAfterSeconds = 30
)

$ErrorActionPreference = 'Stop'
$secretPath = Join-Path $env:LOCALAPPDATA "CodexAdmin\secrets\$Name.secret"
if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
    throw "DPAPI secret '$Name' does not exist."
}

$secure = Get-Content -LiteralPath $secretPath -Raw | ConvertTo-SecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    Set-Clipboard -Value $plainText
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plainText = $null
    $secure = $null
}

if (-not ('CodexAdminClipboard.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
namespace CodexAdminClipboard {
    using System.Runtime.InteropServices;
    public static class NativeMethods {
        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();
    }
}
'@
}

$sequence = [CodexAdminClipboard.NativeMethods]::GetClipboardSequenceNumber()
$clearScript = Join-Path $PSScriptRoot 'Clear-HomelabClipboardAfterDelay.ps1'
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$arguments = @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
    '-File', $clearScript,
    '-AfterSeconds', $ClearAfterSeconds,
    '-ExpectedSequence', $sequence
)
Start-Process -FilePath $pwsh -ArgumentList $arguments -WindowStyle Hidden | Out-Null

Write-Output "Copied DPAPI secret '$Name' to the clipboard; unchanged clipboard content will be cleared after $ClearAfterSeconds seconds."
