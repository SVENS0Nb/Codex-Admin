[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Identity', 'List', 'Create', 'Update', 'UpdateEndpoints', 'Copy', 'Delete', 'SelfTest')]
    [string]$Action,

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$Id,

    [ValidateRange(5, 300)]
    [int]$ClearAfterSeconds = 30
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$storeRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\secret-ui'

function Write-Json {
    param([Parameter(Mandatory)]$Value)
    ConvertTo-Json -InputObject $Value -Depth 6 -Compress
}

function Set-PrivateAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Directory
    )

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = if ($Directory) {
        New-Object Security.AccessControl.DirectorySecurity
    }
    else {
        New-Object Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = if ($Directory) {
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    else {
        [Security.AccessControl.InheritanceFlags]::None
    }
    $propagation = [Security.AccessControl.PropagationFlags]::None
    foreach ($principal in @($identity, 'NT AUTHORITY\SYSTEM')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $principal,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Initialize-Store {
    if (-not (Test-Path -LiteralPath $storeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $storeRoot -Force | Out-Null
        Set-PrivateAcl -Path $storeRoot -Directory
    }
}

function Get-RecordPath {
    param([Parameter(Mandatory)][string]$RecordId)
    if ($RecordId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'Invalid record identifier.'
    }
    Join-Path $storeRoot "$RecordId.vault.secret"
}

function Read-ProtectedRecord {
    param([Parameter(Mandatory)][string]$Path)

    $secure = Get-Content -LiteralPath $Path -Raw | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $json = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        try {
            $json | ConvertFrom-Json
        }
        catch {
            throw 'Encrypted record metadata is invalid.'
        }
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $json = $null
        $secure = $null
    }
}

function Write-ProtectedRecord {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Replace
    )

    $json = $Record | ConvertTo-Json -Depth 5 -Compress
    $secure = ConvertTo-SecureString $json -AsPlainText -Force
    $cipherText = $secure | ConvertFrom-SecureString
    $tempPath = Join-Path $storeRoot ".$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $cipherText | Set-Content -LiteralPath $tempPath -Encoding ascii -NoNewline
        Set-PrivateAcl -Path $tempPath
        if ($Replace) {
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
        }
        else {
            Move-Item -LiteralPath $tempPath -Destination $Path
        }
    }
    finally {
        $json = $null
        $cipherText = $null
        $secure = $null
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Test-DpapiRoundTrip {
    $value = [guid]::NewGuid().ToString('N')
    $secure = ConvertTo-SecureString $value -AsPlainText -Force
    $cipherText = $secure | ConvertFrom-SecureString
    $roundTripSecure = $cipherText | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($roundTripSecure)
    try {
        $roundTrip = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ($roundTrip -cne $value) {
            throw 'Windows DPAPI round-trip failed.'
        }
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $value = $null
        $roundTrip = $null
        $cipherText = $null
        $roundTripSecure = $null
        $secure = $null
    }
}

function Read-RequestBody {
    $body = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($body) -or $body.Length -gt 65536) {
        throw 'Request body is empty or too large.'
    }
    try {
        $body | ConvertFrom-Json
    }
    catch {
        throw 'Request body is not valid JSON.'
    }
    finally {
        $body = $null
    }
}

function Get-Text {
    param(
        $Value,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][int]$Maximum,
        [switch]$Required
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $text = $text.Trim()
    if ($Required -and [string]::IsNullOrWhiteSpace($text)) {
        throw "$Field is required."
    }
    if ($text.Length -gt $Maximum -or $text.Contains([char]0)) {
        throw "$Field is invalid."
    }
    $text
}

function Get-Endpoint {
    param($Value)

    $endpoint = Get-Text -Value $Value -Field 'Endpoint' -Maximum 512
    if ($endpoint.Contains([char]13) -or $endpoint.Contains([char]10)) {
        throw 'Endpoint is invalid.'
    }
    $endpoint
}

function Get-QueryParameters {
    param([Parameter(Mandatory)][Uri]$Uri)

    $parameters = @{}
    foreach ($pair in $Uri.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $pair.Split('=', 2)
        $key = [Net.WebUtility]::UrlDecode($parts[0]).ToLowerInvariant()
        $value = if ($parts.Count -eq 2) { [Net.WebUtility]::UrlDecode($parts[1]) } else { '' }
        $parameters[$key] = $value
    }
    $parameters
}

function Assert-TotpSecret {
    param([Parameter(Mandatory)][string]$Value)

    $seed = $Value
    if ($Value.StartsWith('otpauth://', [StringComparison]::OrdinalIgnoreCase)) {
        $uri = [Uri]$Value
        if (-not $uri.Scheme.Equals('otpauth', [StringComparison]::OrdinalIgnoreCase) -or
            -not $uri.Host.Equals('totp', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Only otpauth://totp URIs are supported.'
        }
        $parameters = Get-QueryParameters -Uri $uri
        $seed = $parameters.secret
        if ($parameters.algorithm -and $parameters.algorithm.ToUpperInvariant() -notin @('SHA1', 'SHA256', 'SHA512')) {
            throw 'Unsupported TOTP algorithm.'
        }
        if ($parameters.digits -and [int]$parameters.digits -notin @(6, 7, 8)) {
            throw 'Unsupported TOTP digit count.'
        }
        if ($parameters.period -and ([int]$parameters.period -lt 15 -or [int]$parameters.period -gt 120)) {
            throw 'Unsupported TOTP period.'
        }
    }

    $normalized = ($seed -replace '[\s=-]', '').ToUpperInvariant()
    if ($normalized.Length -lt 16 -or $normalized -notmatch '^[A-Z2-7]+$') {
        throw 'The TOTP seed is not valid Base32 data.'
    }
}

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
        [Parameter(Mandatory)][string]$StoredValue,
        [long]$UnixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    )

    $seed = $StoredValue
    $algorithm = 'SHA1'
    $digits = 6
    $period = 30
    if ($StoredValue.StartsWith('otpauth://', [StringComparison]::OrdinalIgnoreCase)) {
        $uri = [Uri]$StoredValue
        $parameters = Get-QueryParameters -Uri $uri
        $seed = $parameters.secret
        if ($parameters.algorithm) { $algorithm = $parameters.algorithm.ToUpperInvariant() }
        if ($parameters.digits) { $digits = [int]$parameters.digits }
        if ($parameters.period) { $period = [int]$parameters.period }
    }

    $key = ConvertFrom-Base32 -Value $seed
    $counter = [Math]::Floor($UnixTime / $period)
    $counterBytes = [BitConverter]::GetBytes([long]$counter)
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($counterBytes)
    }

    $hmac = switch ($algorithm) {
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
    $modulus = [int][Math]::Pow(10, $digits)
    ($binary % $modulus).ToString("D$digits")
}

function Copy-ProtectedValue {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][int]$Delay
    )

    Set-Clipboard -Value $Value
    if (-not ('CodexAdminClipboard.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @"
namespace CodexAdminClipboard {
    using System.Runtime.InteropServices;
    public static class NativeMethods {
        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();
    }
}
"@
    }

    $sequence = [CodexAdminClipboard.NativeMethods]::GetClipboardSequenceNumber()
    $clearScript = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\scripts\Clear-HomelabClipboardAfterDelay.ps1')).Path
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
        '-File', $clearScript,
        '-AfterSeconds', $Delay,
        '-ExpectedSequence', $sequence
    )
    Start-Process -FilePath $pwsh -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function ConvertTo-PublicRecord {
    param([Parameter(Mandatory)]$Record)

    $internalEndpoint = [string]$Record.internalEndpoint
    if ([string]::IsNullOrWhiteSpace($internalEndpoint)) {
        $internalEndpoint = [string]$Record.endpoint
    }
    $externalEndpoint = [string]$Record.externalEndpoint

    [ordered]@{
        id = $Record.id
        system = $Record.system
        internalEndpoint = $internalEndpoint
        externalEndpoint = $externalEndpoint
        label = $Record.label
        username = $Record.username
        type = $Record.type
        notes = $Record.notes
        createdAt = $Record.createdAt
        updatedAt = $Record.updatedAt
    }
}

if ($Action -ne 'SelfTest') {
    Initialize-Store
}

switch ($Action) {
    'Identity' {
        Test-DpapiRoundTrip
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $count = @(Get-ChildItem -LiteralPath $storeRoot -Filter '*.vault.secret' -File).Count
        Write-Json ([ordered]@{ user = $identity; recordCount = $count })
    }
    'List' {
        $records = foreach ($file in Get-ChildItem -LiteralPath $storeRoot -Filter '*.vault.secret' -File) {
            ConvertTo-PublicRecord (Read-ProtectedRecord -Path $file.FullName)
        }
        $sortedRecords = @($records | Sort-Object system, label, username)
        ConvertTo-Json -InputObject $sortedRecords -Depth 6 -Compress
    }
    'Create' {
        $inputRecord = Read-RequestBody
        $type = Get-Text -Value $inputRecord.type -Field 'Type' -Maximum 20 -Required
        if ($type -notin @('password', 'api_key', 'totp')) {
            throw 'Unsupported secret type.'
        }

        $secret = Get-Text -Value $inputRecord.secret -Field 'Secret' -Maximum 16384 -Required
        if ($type -eq 'totp') {
            Assert-TotpSecret -Value $secret
        }

        $recordId = [guid]::NewGuid().ToString('D')
        $now = [DateTimeOffset]::UtcNow.ToString('o')
        $record = [ordered]@{
            schemaVersion = 3
            id = $recordId
            system = Get-Text -Value $inputRecord.system -Field 'System' -Maximum 80 -Required
            internalEndpoint = Get-Endpoint -Value $inputRecord.internalEndpoint
            externalEndpoint = Get-Endpoint -Value $inputRecord.externalEndpoint
            label = Get-Text -Value $inputRecord.label -Field 'Label' -Maximum 80 -Required
            username = Get-Text -Value $inputRecord.username -Field 'Username' -Maximum 160
            type = $type
            notes = Get-Text -Value $inputRecord.notes -Field 'Notes' -Maximum 500
            secret = $secret
            createdAt = $now
            updatedAt = $now
        }
        $path = Get-RecordPath -RecordId $recordId
        if (Test-Path -LiteralPath $path) {
            throw 'Record identifier collision.'
        }
        Write-ProtectedRecord -Record $record -Path $path
        Write-Json (ConvertTo-PublicRecord $record)
        $secret = $null
        $record = $null
        $inputRecord = $null
    }
    'Update' {
        if (-not $Id) { throw 'Record identifier is required.' }
        $path = Get-RecordPath -RecordId $Id
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Record not found.'
        }

        $inputRecord = Read-RequestBody
        $existing = Read-ProtectedRecord -Path $path
        $type = Get-Text -Value $inputRecord.type -Field 'Type' -Maximum 20 -Required
        if ($type -notin @('password', 'api_key', 'totp')) {
            throw 'Unsupported secret type.'
        }

        $newSecret = Get-Text -Value $inputRecord.secret -Field 'Secret' -Maximum 16384
        if ([string]::IsNullOrWhiteSpace($newSecret)) {
            if ($type -ne $existing.type) {
                throw 'A new secret is required when changing the secret type.'
            }
            $secret = [string]$existing.secret
        }
        else {
            $secret = $newSecret
        }
        if ($type -eq 'totp') {
            Assert-TotpSecret -Value $secret
        }

        $record = [ordered]@{
            schemaVersion = 3
            id = [string]$existing.id
            system = Get-Text -Value $inputRecord.system -Field 'System' -Maximum 80 -Required
            internalEndpoint = Get-Endpoint -Value $inputRecord.internalEndpoint
            externalEndpoint = Get-Endpoint -Value $inputRecord.externalEndpoint
            label = Get-Text -Value $inputRecord.label -Field 'Label' -Maximum 80 -Required
            username = Get-Text -Value $inputRecord.username -Field 'Username' -Maximum 160
            type = $type
            notes = Get-Text -Value $inputRecord.notes -Field 'Notes' -Maximum 500
            secret = $secret
            createdAt = [string]$existing.createdAt
            updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Write-ProtectedRecord -Record $record -Path $path -Replace
        Write-Json (ConvertTo-PublicRecord $record)
        $newSecret = $null
        $secret = $null
        $record = $null
        $existing = $null
        $inputRecord = $null
    }
    'UpdateEndpoints' {
        if (-not $Id) { throw 'Record identifier is required.' }
        $path = Get-RecordPath -RecordId $Id
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Record not found.'
        }

        $inputRecord = Read-RequestBody
        $hasInternalEndpoint = $inputRecord.PSObject.Properties.Name -contains 'internalEndpoint'
        $hasExternalEndpoint = $inputRecord.PSObject.Properties.Name -contains 'externalEndpoint'
        if (-not $hasInternalEndpoint -and -not $hasExternalEndpoint) {
            throw 'At least one endpoint field is required.'
        }

        $existing = Read-ProtectedRecord -Path $path
        $record = [ordered]@{}
        foreach ($property in $existing.PSObject.Properties) {
            $record[$property.Name] = $property.Value
        }
        if ($hasInternalEndpoint) {
            $record.internalEndpoint = Get-Endpoint -Value $inputRecord.internalEndpoint
        }
        if ($hasExternalEndpoint) {
            $record.externalEndpoint = Get-Endpoint -Value $inputRecord.externalEndpoint
        }
        $record.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')

        Write-ProtectedRecord -Record $record -Path $path -Replace
        $verified = Read-ProtectedRecord -Path $path
        $unexpectedChange = $false
        foreach ($property in $existing.PSObject.Properties) {
            if ($property.Name -in @('internalEndpoint', 'externalEndpoint', 'updatedAt')) {
                continue
            }
            if ([string]$verified.($property.Name) -cne [string]$property.Value) {
                $unexpectedChange = $true
                break
            }
        }
        if ($unexpectedChange) {
            Write-ProtectedRecord -Record $existing -Path $path -Replace
            throw 'Endpoint update changed protected record data and was rolled back.'
        }
        Write-Json (ConvertTo-PublicRecord $record)
        $verified = $null
        $record = $null
        $existing = $null
        $inputRecord = $null
    }
    'Copy' {
        if (-not $Id) { throw 'Record identifier is required.' }
        $path = Get-RecordPath -RecordId $Id
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Record not found.'
        }
        $record = Read-ProtectedRecord -Path $path
        $value = if ($record.type -eq 'totp') {
            Get-TotpCode -StoredValue ([string]$record.secret)
        }
        else {
            [string]$record.secret
        }
        Copy-ProtectedValue -Value $value -Delay $ClearAfterSeconds
        $value = $null
        $record = $null
        Write-Json ([ordered]@{ ok = $true; id = $Id; clearsAfterSeconds = $ClearAfterSeconds })
    }
    'Delete' {
        if (-not $Id) { throw 'Record identifier is required.' }
        $path = Get-RecordPath -RecordId $Id
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'Record not found.'
        }
        Remove-Item -LiteralPath $path -Force
        Write-Json ([ordered]@{ ok = $true; id = $Id })
    }
    'SelfTest' {
        $actual = Get-TotpCode -StoredValue 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTime 59
        if ($actual -ne '287082') {
            throw 'RFC 6238 self-test failed.'
        }
        Write-Json ([ordered]@{ ok = $true; test = 'RFC 6238' })
    }
}
