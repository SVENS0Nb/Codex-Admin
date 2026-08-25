[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{1,63}$')]
    [string]$Name,

    [switch]$FromClipboard
)

$ErrorActionPreference = 'Stop'
$secretRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\secrets'
$secretPath = Join-Path $secretRoot "$Name.secret"
New-Item -ItemType Directory -Path $secretRoot -Force | Out-Null

if ($FromClipboard) {
    $plainText = (Get-Clipboard -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($plainText)) {
        throw 'The clipboard does not contain a secret.'
    }
    $secret = ConvertTo-SecureString $plainText -AsPlainText -Force
}
else {
    $secret = Read-Host "Enter secret for '$Name'" -AsSecureString
}

try {
    $secret | ConvertFrom-SecureString | Set-Content -LiteralPath $secretPath -Encoding ascii -NoNewline
}
finally {
    $plainText = $null
    $secret = $null
    if ($FromClipboard) {
        Set-Clipboard -Value ''
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')))
Set-Acl -LiteralPath $secretPath -AclObject $acl

Write-Output "Stored '$Name' with Windows DPAPI for the current user."
