[CmdletBinding()]
param(
    [string]$HostAddress = '192.0.2.40',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$InstanceId = '00000000-0000-4000-8000-000000000001',
    [ValidateRange(1, 500)]
    [int]$AuditCount = 200,
    [ValidateRange(1024, 1048576)]
    [int]$MaximumFileBytes = 262144,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.runtime\minecraft-amp-diagnostics.json')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'CodexAdmin.Common.psm1') -Force
$store = (Resolve-Path (Join-Path $repositoryRoot 'apps\secret-ui\backend\SecretUiStore.ps1')).Path
$accessProfiles = Get-Content -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\access-profiles.json') -Raw | ConvertFrom-Json
$profile = @($accessProfiles.profiles | Where-Object id -eq 'minecraft-amp-api-admin') | Select-Object -First 1
if (-not $profile) {
    throw 'The minecraft-amp-api-admin access profile is unavailable.'
}

function Get-VaultClipboardValue {
    param([Parameter(Mandatory)][string]$RecordId)

    & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $store `
        -Action Copy -Id $RecordId -ClearAfterSeconds 5 | Out-Null
    $value = (Get-Clipboard -Raw).TrimEnd("`r", "`n")
    Set-Clipboard -Value ''
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Vault value is unavailable.'
    }
    $value
}

function Unwrap-AmpResult {
    param($Response)

    if ($null -ne $Response -and $Response.PSObject.Properties.Name -contains 'result') {
        return $Response.result
    }
    $Response
}

function Invoke-AmpApi {
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [string]$SessionId,
        [switch]$RawResponse
    )

    $body = [ordered]@{}
    foreach ($item in $Parameters.GetEnumerator()) {
        $body[$item.Key] = $item.Value
    }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $body.SESSIONID = $SessionId
    }
    $response = Invoke-RestMethod -Method Post -Uri "$BaseUri/$Method" `
        -ContentType 'application/json' -Headers @{ Accept = 'application/json' } `
        -Body ($body | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec 30
    if ($RawResponse) { return $response }
    Unwrap-AmpResult $response
}

function ConvertTo-SafeString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return $null }
    $safe = $Value
    $safe = $safe -replace '(?i)(authorization\s*[:=]\s*)([^\s,;]+)', '$1<redacted>'
    $safe = $safe -replace '(?i)((?:password|passwd|token|session(?:id)?|secret|api[_ -]?key|rcon\.password)\s*[:=]\s*)([^\s,;]+)', '$1<redacted>'
    $safe = $safe -replace '(?i)((?:password|passwd|token|session(?:id)?|secret|api[_ -]?key|rcon\.password)\s+(?:to|is)\s+)(?:"[^"]*"|''[^'']*''|[^\r\n]+)', '$1<redacted>'
    $safe = $safe -replace '(?i)(-----BEGIN [A-Z ]*PRIVATE KEY-----)[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----)', '$1<redacted>$2'
    $safe
}

function ConvertTo-SafeObject {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return ConvertTo-SafeString $Value }
    if ($Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $safeMap = [ordered]@{}
        foreach ($key in $Value.Keys) {
            if ([string]$key -match '(?i)password|passwd|token|session|secret|authorization|cookie|private.?key|api.?key') {
                $safeMap[[string]$key] = '<redacted>'
            }
            else {
                $safeMap[[string]$key] = ConvertTo-SafeObject $Value[$key]
            }
        }
        return [pscustomobject]$safeMap
    }
    if ($Value -is [Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-SafeObject $_ })
    }

    $safeObject = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.Name -match '(?i)password|passwd|token|session|secret|authorization|cookie|private.?key|api.?key') {
            $safeObject[$property.Name] = '<redacted>'
        }
        else {
            $safeObject[$property.Name] = ConvertTo-SafeObject $property.Value
        }
    }
    [pscustomobject]$safeObject
}

function Get-ErrorText {
    param([Parameter(Mandatory)][scriptblock]$Action)

    try {
        & $Action
    }
    catch {
        [pscustomobject]@{ unavailable = $true; reason = ConvertTo-SafeString $_.Exception.Message }
    }
}

function Get-DirectoryListing {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    Get-ErrorText {
        Invoke-AmpApi -BaseUri $script:childBase -Method 'FileManagerPlugin/GetDirectoryListing' `
            -Parameters @{ Dir = $Path } -SessionId $script:childSession
    }
}

function Read-AmpTextFile {
    param([Parameter(Mandatory)][string]$Path)

    $result = Get-ErrorText {
        Invoke-AmpApi -BaseUri $script:childBase -Method 'FileManagerPlugin/ReadFileChunk' `
            -Parameters @{ Filename = $Path; Offset = 0; ChunkSize = $MaximumFileBytes } `
            -SessionId $script:childSession
    }
    if ($result -is [string] -and $result -match '^[A-Za-z0-9+/]*={0,2}$') {
        try {
            $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($result))
            $result = ConvertTo-SafeString $decoded
            $decoded = $null
        }
        catch { }
    }
    ConvertTo-SafeObject $result
}

$adsBase = "http://$HostAddress`:8080/API"
$script:childBase = "$adsBase/ADSModule/Servers/$InstanceId/API"
$adsSession = $null
$script:childSession = $null
$password = $null
$temporaryToken = $null

try {
    $password = Get-VaultClipboardValue ([string]$profile.credential_ref)
    $adsLogin = Invoke-AmpApi -BaseUri $adsBase -Method 'Core/Login' -RawResponse -Parameters @{
        username = [string]$profile.identity
        password = $password
        token = ''
        rememberMe = $false
    }
    $password = $null
    if (-not $adsLogin.success -or [string]::IsNullOrWhiteSpace([string]$adsLogin.sessionID)) {
        throw 'AMP ADS authentication failed.'
    }
    $adsSession = [string]$adsLogin.sessionID

    $managed = Invoke-AmpApi -BaseUri $adsBase -Method 'ADSModule/ManageInstance' `
        -Parameters @{ InstanceId = $InstanceId } -SessionId $adsSession
    $temporaryToken = [string]$managed
    if ($managed.PSObject.Properties.Name -contains 'token') {
        $temporaryToken = [string]$managed.token
    }
    if ([string]::IsNullOrWhiteSpace($temporaryToken)) {
        throw 'AMP did not return an instance-management token.'
    }

    $childLogin = Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/Login' -RawResponse -Parameters @{
        username = [string]$profile.identity
        password = ''
        token = $temporaryToken
        rememberMe = $false
    }
    $temporaryToken = $null
    if (-not $childLogin.success -or [string]::IsNullOrWhiteSpace([string]$childLogin.sessionID)) {
        throw 'AMP child-instance authentication failed.'
    }
    $script:childSession = [string]$childLogin.sessionID

    $calls = [ordered]@{
        failure_reason = { Invoke-AmpApi -BaseUri $script:childBase -Method 'MinecraftModule/GetFailureReason' -Parameters @{} -SessionId $script:childSession }
        module_info = { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetModuleInfo' -Parameters @{} -SessionId $script:childSession }
        status = { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetStatus' -Parameters @{} -SessionId $script:childSession }
        updates = { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetUpdates' -Parameters @{} -SessionId $script:childSession }
        diagnostics = { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetDiagnosticsInfo' -Parameters @{} -SessionId $script:childSession }
        structured_diagnostics = { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetStructuredDiagnostics' -Parameters @{} -SessionId $script:childSession }
        port_summaries = { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetPortSummaries' -Parameters @{} -SessionId $script:childSession }
        audit_log = { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetAuditLogEntries' -Parameters @{ Before = $null; Count = $AuditCount } -SessionId $script:childSession }
        backups = { Invoke-AmpApi -BaseUri $script:childBase -Method 'LocalFileBackupPlugin/GetBackups' -Parameters @{} -SessionId $script:childSession }
        backup_will_stop_server = { Invoke-AmpApi -BaseUri $script:childBase -Method 'LocalFileBackupPlugin/BackupWillStopServer' -Parameters @{} -SessionId $script:childSession }
    }

    $result = [ordered]@{
        generated_at = [DateTimeOffset]::Now.ToString('o')
        target = [ordered]@{
            system_id = 'game_server'
            host = $HostAddress
            instance_id = $InstanceId
        }
    }
    foreach ($call in $calls.GetEnumerator()) {
        $result[$call.Key] = ConvertTo-SafeObject (Get-ErrorText $call.Value)
    }

    $directories = [ordered]@{}
    foreach ($path in @('', '.', './', 'logs', 'logs/', 'plugins/', 'versions/', 'AMP_Logs', 'AMP_Logs/', 'LocalBackups', 'LocalBackups/')) {
        $label = if ([string]::IsNullOrEmpty($path)) { '<empty>' } else { $path }
        $directories[$label] = ConvertTo-SafeObject (Get-DirectoryListing -Path $path)
    }
    $result.directories = $directories

    $files = [ordered]@{}
    foreach ($path in @('server.properties', 'eula.txt', 'logs/latest.log', 'Minecraft/server.properties', 'Minecraft/eula.txt', 'Minecraft/logs/latest.log')) {
        $files[$path] = Read-AmpTextFile -Path $path
    }
    $result.files = $files

    $safeResult = ConvertTo-SafeObject ([pscustomobject]$result)
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.runtime'))
    if (-not $resolvedOutput.StartsWith($runtimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output must stay below the repository .runtime directory.'
    }
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $safeResult | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8

    [pscustomobject]@{
        success = $true
        generated_at = $safeResult.generated_at
        output_path = $resolvedOutput
        failure_reason = $safeResult.failure_reason
        status = $safeResult.status
    }
}
finally {
    if ($script:childSession) {
        try { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/Logout' -Parameters @{} -SessionId $script:childSession | Out-Null } catch { }
    }
    if ($adsSession) {
        try { Invoke-AmpApi -BaseUri $adsBase -Method 'Core/Logout' -Parameters @{} -SessionId $adsSession | Out-Null } catch { }
    }
    $password = $null
    $temporaryToken = $null
    $script:childSession = $null
    $adsSession = $null
    Set-Clipboard -Value ''
}
