[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Generate', Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9._-]{1,63}$')]
    [string]$Name,

    [Parameter(ParameterSetName = 'SelfTest', Mandatory)]
    [switch]$SelfTest,

    [ValidateRange(5, 300)]
    [int]$ClearAfterSeconds = 30
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-Base32 {
    param([Parameter(Mandatory)][string]$Value)

    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $normalized = ($Value -replace '[\s=-]', '').ToUpperInvariant()
    if ($normalized -notmatch '^[A-Z2-7]+$') {
        throw 'Invalid Base32 TOTP seed.'
    }

    $bytes = [Collections.Generic.List[byte]]::new()
    $buffer = 0
    $bits = 0
    foreach ($character in $normalized.ToCharArray()) {
        $index = $alphabet.IndexOf($character)
        $buffer = ($buffer -shl 5) -bor $index
        $bits += 5
        while ($bits -ge 8) {
            $bits -= 8
            $bytes.Add([byte](($buffer -shr $bits) -band 0xff))
            if ($bits -eq 0) {
                $buffer = 0
            }
            else {
                $buffer = $buffer -band ((1 -shl $bits) - 1)
            }
        }
    }
    $bytes.ToArray()
}

function Get-TotpCode {
    param(
        [Parameter(Mandatory)][string]$Seed,
        [Parameter(Mandatory)][long]$UnixTime,
        [ValidateSet('SHA1', 'SHA256', 'SHA512')][string]$Algorithm = 'SHA1',
        [ValidateRange(6, 8)][int]$Digits = 6,
        [ValidateRange(15, 120)][int]$Period = 30
    )

    $key = ConvertFrom-Base32 -Value $Seed
    $counter = [Math]::Floor($UnixTime / $Period)
    $counterBytes = [BitConverter]::GetBytes([long]$counter)
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($counterBytes)
    }

    $hmac = switch ($Algorithm) {
        'SHA256' { [Security.Cryptography.HMACSHA256]::new($key) }
        'SHA512' { [Security.Cryptography.HMACSHA512]::new($key) }
        default  { [Security.Cryptography.HMACSHA1]::new($key) }
    }
    try {
        $hash = $hmac.ComputeHash($counterBytes)
    }
    finally {
        $hmac.Dispose()
        [Array]::Clear($key, 0, $key.Length)
    }

    $offset = $hash[$hash.Length - 1] -band 0x0f
    $binary = (($hash[$offset] -band 0x7f) -shl 24) -bor
              (($hash[$offset + 1] -band 0xff) -shl 16) -bor
              (($hash[$offset + 2] -band 0xff) -shl 8) -bor
              ($hash[$offset + 3] -band 0xff)
    $modulus = [int][Math]::Pow(10, $Digits)
    ($binary % $modulus).ToString("D$Digits")
}

if ($SelfTest) {
    $testSeed = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
    $actual = Get-TotpCode -Seed $testSeed -UnixTime 59 -Algorithm SHA1 -Digits 8 -Period 30
    if ($actual -ne '94287082') {
        throw 'RFC 6238 self-test failed.'
    }
    Write-Output 'RFC 6238 TOTP self-test passed.'
    return
}

$secretPath = Join-Path $env:LOCALAPPDATA "CodexAdmin\secrets\$Name.totp.secret"
if (-not (Test-Path -LiteralPath $secretPath -PathType Leaf)) {
    throw "TOTP seed '$Name' does not exist."
}

$secure = Get-Content -LiteralPath $secretPath -Raw | ConvertTo-SecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $storedValue = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
    $seed = $storedValue
    $algorithm = 'SHA1'
    $digits = 6
    $period = 30
    if ($storedValue.StartsWith('otpauth://', [StringComparison]::OrdinalIgnoreCase)) {
        $uri = [Uri]$storedValue
        $pairs = $uri.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)
        $parameters = @{}
        foreach ($pair in $pairs) {
            $parts = $pair.Split('=', 2)
            $parameters[[Net.WebUtility]::UrlDecode($parts[0]).ToLowerInvariant()] =
                if ($parts.Count -eq 2) { [Net.WebUtility]::UrlDecode($parts[1]) } else { '' }
        }
        $seed = $parameters.secret
        if ($parameters.algorithm) { $algorithm = $parameters.algorithm.ToUpperInvariant() }
        if ($parameters.digits) { $digits = [int]$parameters.digits }
        if ($parameters.period) { $period = [int]$parameters.period }
    }

    $code = Get-TotpCode -Seed $seed -UnixTime ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) `
        -Algorithm $algorithm -Digits $digits -Period $period
    Set-Clipboard -Value $code
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $storedValue = $null
    $seed = $null
    $code = $null
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

Write-Output "Copied TOTP code '$Name' to the clipboard; unchanged clipboard content will be cleared after $ClearAfterSeconds seconds."
