[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [switch]$Apply,
    [ValidateSet('26.2')]
    [string]$TargetPaperVersion = '26.2',
    [string]$HostAddress = '192.0.2.40',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$InstanceId = '00000000-0000-4000-8000-000000000001',
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.runtime\minecraft-paper-repair.json')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'CodexAdmin.Common.psm1') -Force
$store = (Resolve-Path (Join-Path $repositoryRoot 'apps\secret-ui\backend\SecretUiStore.ps1')).Path
$profiles = Get-Content -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\access-profiles.json') -Raw | ConvertFrom-Json
$profile = @($profiles.profiles | Where-Object id -eq 'minecraft-amp-api-admin') | Select-Object -First 1
if (-not $profile) { throw 'The minecraft-amp-api-admin access profile is unavailable.' }

function Get-VaultClipboardValue {
    param([Parameter(Mandatory)][string]$RecordId)
    & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $store `
        -Action Copy -Id $RecordId -ClearAfterSeconds 5 | Out-Null
    try {
        $value = (Get-Clipboard -Raw).TrimEnd("`r", "`n")
        if ([string]::IsNullOrWhiteSpace($value)) { throw 'Vault value is unavailable.' }
        $value
    }
    finally { Set-Clipboard -Value '' }
}

function Invoke-AmpApi {
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [string]$SessionId,
        [switch]$RawResponse,
        [int]$TimeoutSec = 30
    )
    $body = [ordered]@{}
    foreach ($item in $Parameters.GetEnumerator()) { $body[$item.Key] = $item.Value }
    if ($SessionId) { $body.SESSIONID = $SessionId }
    $response = Invoke-RestMethod -Method Post -Uri "$BaseUri/$Method" `
        -ContentType 'application/json' -Headers @{ Accept = 'application/json' } `
        -Body ($body | ConvertTo-Json -Depth 30 -Compress) -TimeoutSec $TimeoutSec
    if ($RawResponse) { return $response }
    if ($response.PSObject.Properties.Name -contains 'result') { return $response.result }
    $response
}

function Get-CurrentConfigValue {
    param([Parameter(Mandatory)][string]$Node)
    $config = Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetConfig' `
        -Parameters @{ node = $Node } -SessionId $script:childSession
    $config.CurrentValue
}

function Get-PaperJarMetadata {
    $listing = @(Invoke-AmpApi -BaseUri $script:childBase -Method 'FileManagerPlugin/GetDirectoryListing' `
        -Parameters @{ Dir = '' } -SessionId $script:childSession)
    $jar = @($listing | Where-Object Filename -eq 'paperclip.jar') | Select-Object -First 1
    if (-not $jar) { return $null }
    [pscustomobject]@{ size_bytes = [long]$jar.SizeBytes; modified = [string]$jar.Modified }
}

function Get-GameStatus {
    $status = Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetStatus' -Parameters @{} -SessionId $script:childSession
    $gamePort = @($status.Ports | Where-Object Port -eq 25565) | Select-Object -First 1
    [pscustomobject]@{
        state = $status.State
        uptime = [string]$status.Uptime
        game_port_listening = [bool]$gamePort.Listening
        game_port_listeners = [int]$gamePort.ListeningCount
        memory_mb = $status.Metrics.'Memory Usage'.RawValue
    }
}

function Get-BackupList {
    @(Invoke-AmpApi -BaseUri $script:childBase -Method 'LocalFileBackupPlugin/GetBackups' `
        -Parameters @{} -SessionId $script:childSession)
}

function ConvertFrom-AmpTimestamp {
    param([Parameter(Mandatory)][string]$Value)

    $parsed = [DateTimeOffset]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
        [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([DateTimeOffset]::TryParseExact($Value, 'MM/dd/yyyy HH:mm:ss', $culture, $styles, [ref]$parsed)) {
        return $parsed
    }
    throw "AMP returned an unsupported backup timestamp format."
}

function Wait-ForBackup {
    param([int]$PreviousCount, [DateTimeOffset]$Deadline)
    do {
        Start-Sleep -Seconds 2
        $backups = @(Get-BackupList)
        if ($backups.Count -gt $PreviousCount) { return $backups }
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    throw 'The AMP local backup did not become visible before the safety deadline.'
}

function Wait-ForPaperJarChange {
    param($Before, [DateTimeOffset]$Deadline)
    do {
        Start-Sleep -Seconds 3
        $current = Get-PaperJarMetadata
        if ($current -and (-not $Before -or $current.modified -ne $Before.modified -or $current.size_bytes -ne $Before.size_bytes)) {
            return $current
        }
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    throw 'The Paper update did not produce a changed paperclip.jar before the safety deadline.'
}

function Wait-ForGameStart {
    param([DateTimeOffset]$Deadline)
    $last = $null
    do {
        Start-Sleep -Seconds 2
        $last = Get-GameStatus
        if ($last.game_port_listening) { return $last }
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    $script:lastFailedStatus = $last
    throw 'Minecraft did not open TCP 25565 before the verification deadline.'
}

if (-not $Apply) { throw 'Use -Apply only after an explicitly authorized repair request.' }

$adsBase = "http://$HostAddress`:8080/API"
$script:childBase = "$adsBase/ADSModule/Servers/$InstanceId/API"
$adsSession = $null
$script:childSession = $null
$password = $null
$temporaryToken = $null
$beforeVersion = $null
$versionChanged = $false
$rollbackAttempted = $false
$rollbackSucceeded = $false
$result = [ordered]@{
    generated_at = [DateTimeOffset]::Now.ToString('o')
    target = [ordered]@{ system_id = 'game_server'; instance_id = $InstanceId }
    requested_version = $TargetPaperVersion
    backup = $null
    before = $null
    after = $null
    change_result = 'not_started'
    rollback = 'not_required'
}

try {
    $password = Get-VaultClipboardValue ([string]$profile.credential_ref)
    $adsLogin = Invoke-AmpApi -BaseUri $adsBase -Method 'Core/Login' -RawResponse -Parameters @{
        username = [string]$profile.identity; password = $password; token = ''; rememberMe = $false
    }
    $password = $null
    if (-not $adsLogin.success -or -not $adsLogin.sessionID) { throw 'AMP ADS authentication failed.' }
    $adsSession = [string]$adsLogin.sessionID
    $managed = Invoke-AmpApi -BaseUri $adsBase -Method 'ADSModule/ManageInstance' `
        -Parameters @{ InstanceId = $InstanceId } -SessionId $adsSession
    $temporaryToken = if ($managed.PSObject.Properties.Name -contains 'token') { [string]$managed.token } else { [string]$managed }
    if (-not $temporaryToken) { throw 'AMP did not return an instance-management token.' }
    $childLogin = Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/Login' -RawResponse -Parameters @{
        username = [string]$profile.identity; password = ''; token = $temporaryToken; rememberMe = $false
    }
    $temporaryToken = $null
    if (-not $childLogin.success -or -not $childLogin.sessionID) { throw 'AMP child authentication failed.' }
    $script:childSession = [string]$childLogin.sessionID

    $beforeVersion = [string](Get-CurrentConfigValue 'MinecraftModule.Minecraft.SpecificPaperVersion')
    $beforeType = [string](Get-CurrentConfigValue 'MinecraftModule.Minecraft.ServerType')
    $beforeJarSetting = [string](Get-CurrentConfigValue 'MinecraftModule.Minecraft.ServerJAR')
    $beforeAdditional = [string](Get-CurrentConfigValue 'MinecraftModule.Minecraft.AdditionalOpts')
    $beforeJava = [string](Get-CurrentConfigValue 'MinecraftModule.Java.CustomOpts')
    $beforeStatus = Get-GameStatus
    $beforeJar = Get-PaperJarMetadata
    $result.before = [ordered]@{
        paper_version = $beforeVersion
        server_type = $beforeType
        server_jar = $beforeJarSetting
        additional_server_options_empty = [string]::IsNullOrEmpty($beforeAdditional)
        additional_java_options_empty = [string]::IsNullOrEmpty($beforeJava)
        status = $beforeStatus
        paper_jar = $beforeJar
    }
    if ($beforeStatus.game_port_listening) { throw 'Minecraft is already listening; refusing to update a running server.' }
    if ($beforeType -ne '31') { throw "Unexpected server type '$beforeType'; expected Paper type 31." }
    if ($beforeVersion -eq $TargetPaperVersion) { throw "Paper version is already $TargetPaperVersion; no safe version transition is available." }

    $previousBackups = @(Get-BackupList)
    $recentSafetyBackup = @($previousBackups | Where-Object {
        $_.Name -eq "Before Paper $TargetPaperVersion startup repair" -and
        $_.StoredLocally -and $_.Sticky -and
        (ConvertFrom-AmpTimestamp -Value ([string]$_.Timestamp)) -gt [DateTimeOffset]::UtcNow.AddHours(-1)
    } | Sort-Object Timestamp -Descending | Select-Object -First 1)
    $backupReused = [bool]$recentSafetyBackup
    if ($backupReused) {
        $newBackups = $previousBackups
        $newBackup = $recentSafetyBackup
    }
    else {
        $backupResponse = Invoke-AmpApi -BaseUri $script:childBase -Method 'LocalFileBackupPlugin/TakeBackup' -RawResponse `
            -Parameters @{
                Title = "Before Paper $TargetPaperVersion startup repair"
                Description = 'Automatic local safety backup before the approved AMP Paper startup repair.'
                Sticky = $true
                Local = $true
                S3 = $false
                WasCreatedAutomatically = $false
                DirtyOnly = $false
                BackupWhileRunning = $false
            } -SessionId $script:childSession -TimeoutSec 90
        $backupTaskAccepted = ($backupResponse.PSObject.Properties.Name -contains 'Id') -or `
            (($backupResponse.PSObject.Properties.Name -contains 'success') -and [bool]$backupResponse.success)
        if (-not $backupTaskAccepted) { throw 'AMP did not accept the local safety backup task.' }
        $newBackups = @(Wait-ForBackup -PreviousCount $previousBackups.Count -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(3)))
        $newBackup = @($newBackups | Where-Object { $_.Id -notin @($previousBackups.Id) } | Select-Object -First 1)
        if (-not $newBackup) { $newBackup = @($newBackups | Select-Object -First 1) }
    }
    $result.backup = [ordered]@{
        verified = $true
        reused_recent_backup = $backupReused
        count_before = $previousBackups.Count
        count_after = $newBackups.Count
        id = [string]$newBackup.Id
        title = [string]$newBackup.Name
        created = [string]$newBackup.Timestamp
        size_bytes = $newBackup.CompressedSizeBytes
        sticky = $newBackup.Sticky
    }

    Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/SetConfig' -RawResponse `
        -Parameters @{ node = 'MinecraftModule.Minecraft.SpecificPaperVersion'; value = $TargetPaperVersion } `
        -SessionId $script:childSession | Out-Null
    $versionChanged = $true
    $verifiedVersion = [string](Get-CurrentConfigValue 'MinecraftModule.Minecraft.SpecificPaperVersion')
    if ($verifiedVersion -ne $TargetPaperVersion) { throw 'AMP did not retain the requested Paper version.' }

    Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/UpdateApplication' -RawResponse `
        -Parameters @{} -SessionId $script:childSession -TimeoutSec 90 | Out-Null
    $afterJar = Wait-ForPaperJarChange -Before $beforeJar -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(4))

    Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/Start' -RawResponse `
        -Parameters @{} -SessionId $script:childSession -TimeoutSec 30 | Out-Null
    $afterStatus = Wait-ForGameStart -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(3))
    Start-Sleep -Seconds 5
    $stableStatus = Get-GameStatus
    if (-not $stableStatus.game_port_listening) { throw 'Minecraft opened and then lost TCP 25565 during stability verification.' }
    $diagnostics = Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/GetDiagnosticsInfo' -Parameters @{} -SessionId $script:childSession
    if ([string]$diagnostics.'Last Arguments' -match '(?:^|\s)--log-strip-color(?:\s|$)') {
        throw 'AMP still supplied the removed --log-strip-color argument after the version transition.'
    }

    $result.after = [ordered]@{
        paper_version = [string](Get-CurrentConfigValue 'MinecraftModule.Minecraft.SpecificPaperVersion')
        status = $stableStatus
        paper_jar = $afterJar
        removed_argument_absent = $true
        last_executable = [string]$diagnostics.'Last Executable'
    }
    $result.change_result = 'succeeded'
}
catch {
    $result.change_result = 'failed'
    $result.failure = $_.Exception.Message
    if ($versionChanged -and $script:childSession -and $beforeVersion) {
        $rollbackAttempted = $true
        try {
            Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/SetConfig' -RawResponse `
                -Parameters @{ node = 'MinecraftModule.Minecraft.SpecificPaperVersion'; value = $beforeVersion } `
                -SessionId $script:childSession | Out-Null
            $rollbackSucceeded = ([string](Get-CurrentConfigValue 'MinecraftModule.Minecraft.SpecificPaperVersion') -eq $beforeVersion)
        }
        catch { $rollbackSucceeded = $false }
        $result.rollback = if ($rollbackSucceeded) { 'configuration_restored' } else { 'failed' }
    }
    else { $result.rollback = 'not_required' }
}
finally {
    if ($script:childSession) { try { Invoke-AmpApi -BaseUri $script:childBase -Method 'Core/Logout' -Parameters @{} -SessionId $script:childSession | Out-Null } catch { } }
    if ($adsSession) { try { Invoke-AmpApi -BaseUri $adsBase -Method 'Core/Logout' -Parameters @{} -SessionId $adsSession | Out-Null } catch { } }
    $password = $null
    $temporaryToken = $null
    $script:childSession = $null
    $adsSession = $null
    Set-Clipboard -Value ''
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$runtimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.runtime'))
if (-not $resolvedOutput.StartsWith($runtimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output must stay below the repository .runtime directory.'
}
$directory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
[pscustomobject]$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
[pscustomobject]$result

if ($result.change_result -ne 'succeeded') { exit 1 }
