[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{1,63}$')]
    [string]$Name
)

$ErrorActionPreference = 'Stop'
$secretRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\secrets'
$secretPath = Join-Path $secretRoot "$Name.totp.secret"
New-Item -ItemType Directory -Path $secretRoot -Force | Out-Null

$inputSecret = Read-Host "Paste TOTP seed or otpauth URI for '$Name'" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($inputSecret)
try {
    $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
    $seed = $plainText
    if ($plainText.StartsWith('otpauth://', [StringComparison]::OrdinalIgnoreCase)) {
        $uri = [Uri]$plainText
        if (-not $uri.Scheme.Equals('otpauth', [StringComparison]::OrdinalIgnoreCase) -or
            -not $uri.Host.Equals('totp', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Only otpauth://totp URIs are supported.'
        }
        $pairs = $uri.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)
        $parameters = @{}
        foreach ($pair in $pairs) {
            $parts = $pair.Split('=', 2)
            $parameters[[Net.WebUtility]::UrlDecode($parts[0]).ToLowerInvariant()] =
                if ($parts.Count -eq 2) { [Net.WebUtility]::UrlDecode($parts[1]) } else { '' }
        }
        $seed = $parameters.secret
    }

    $normalizedSeed = ($seed -replace '[\s=-]', '').ToUpperInvariant()
    if ($normalizedSeed.Length -lt 16 -or $normalizedSeed -notmatch '^[A-Z2-7]+$') {
        throw 'The TOTP seed is not valid Base32 data.'
    }

    $inputSecret | ConvertFrom-SecureString | Set-Content -LiteralPath $secretPath -Encoding ascii -NoNewline
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plainText = $null
    $seed = $null
    $normalizedSeed = $null
    $inputSecret = $null
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')))
Set-Acl -LiteralPath $secretPath -AclObject $acl

Write-Output "Stored TOTP seed '$Name' with Windows DPAPI for the current user."
