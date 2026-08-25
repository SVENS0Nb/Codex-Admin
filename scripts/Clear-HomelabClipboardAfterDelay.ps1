[CmdletBinding()]
param(
    [ValidateRange(1, 300)]
    [int]$AfterSeconds = 30,

    [Parameter(Mandatory)]
    [uint32]$ExpectedSequence
)

$ErrorActionPreference = 'Stop'

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

Start-Sleep -Seconds $AfterSeconds
if ([CodexAdminClipboard.NativeMethods]::GetClipboardSequenceNumber() -eq $ExpectedSequence) {
    Set-Clipboard -Value ''
}
