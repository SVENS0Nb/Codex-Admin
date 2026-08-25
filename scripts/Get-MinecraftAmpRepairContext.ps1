[CmdletBinding()]
param(
    [string]$HostAddress = '192.0.2.40',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$InstanceId = '00000000-0000-4000-8000-000000000001',
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.runtime\minecraft-amp-repair-context.json')
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
        [switch]$RawResponse
    )
    $body = [ordered]@{}
    foreach ($item in $Parameters.GetEnumerator()) { $body[$item.Key] = $item.Value }
    if ($SessionId) { $body.SESSIONID = $SessionId }
    $response = Invoke-RestMethod -Method Post -Uri "$BaseUri/$Method" `
        -ContentType 'application/json' -Headers @{ Accept = 'application/json' } `
        -Body ($body | ConvertTo-Json -Depth 30 -Compress) -TimeoutSec 30
    if ($RawResponse) { return $response }
    if ($response.PSObject.Properties.Name -contains 'result') { return $response.result }
    $response
}

function Test-SensitiveName {
    param([Parameter(Mandatory)][string]$Name)
    $Name -match '(?i)password|passwd|token|session|secret|authorization|cookie|private.?key|api.?key|licen[cs]e.?key'
}

$candidateList = [Collections.Generic.List[object]]::new()
function Find-SettingCandidate {
    param($Value, [string]$Path = 'root')

    if ($null -eq $Value -or $Value -is [ValueType] -or $Value -is [string]) { return }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Collections.IDictionary]) {
        $index = 0
        foreach ($item in $Value) {
            Find-SettingCandidate -Value $item -Path "$Path[$index]"
            $index++
        }
        return
    }

    $properties = if ($Value -is [Collections.IDictionary]) {
        @($Value.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Value[$_] } })
    }
    else { @($Value.PSObject.Properties) }

    $scalars = [ordered]@{}
    $searchParts = [Collections.Generic.List[string]]::new()
    foreach ($property in $properties) {
        $name = [string]$property.Name
        $itemValue = $property.Value
        if (Test-SensitiveName $name) {
            $scalars[$name] = '<redacted>'
            continue
        }
        if ($null -eq $itemValue -or $itemValue -is [ValueType] -or $itemValue -is [string]) {
            $text = [string]$itemValue
            if ($text.Length -gt 400) { $text = $text.Substring(0, 400) }
            $scalars[$name] = $itemValue
            $searchParts.Add("$name=$text")
        }
    }
    $searchText = ($searchParts -join ' ')
    if ($searchText -match '(?i)paper|server.?type|server.?version|server.?jar|startup.?argument|additional.?argument|command.?line|log.?strip.?color') {
        $enumValues = $null
        $enumProperty = @($properties | Where-Object Name -eq 'EnumValues') | Select-Object -First 1
        if ($enumProperty -and $null -ne $enumProperty.Value) { $enumValues = $enumProperty.Value }
        $candidateList.Add([pscustomobject]@{ path = $Path; fields = [pscustomobject]$scalars; enum_values = $enumValues })
    }

    foreach ($property in $properties) {
        if ($null -ne $property.Value -and $property.Value -isnot [string] -and $property.Value -isnot [ValueType]) {
            Find-SettingCandidate -Value $property.Value -Path "$Path.$($property.Name)"
        }
    }
}

$adsBase = "http://$HostAddress`:8080/API"
$childBase = "$adsBase/ADSModule/Servers/$InstanceId/API"
$adsSession = $null
$childSession = $null
$password = $null
$temporaryToken = $null
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
    $childLogin = Invoke-AmpApi -BaseUri $childBase -Method 'Core/Login' -RawResponse -Parameters @{
        username = [string]$profile.identity; password = ''; token = $temporaryToken; rememberMe = $false
    }
    $temporaryToken = $null
    if (-not $childLogin.success -or -not $childLogin.sessionID) { throw 'AMP child authentication failed.' }
    $childSession = [string]$childLogin.sessionID

    $settings = Invoke-AmpApi -BaseUri $childBase -Method 'Core/GetSettingsSpec' -Parameters @{} -SessionId $childSession
    Find-SettingCandidate -Value $settings
    $apiSpec = Invoke-AmpApi -BaseUri $childBase -Method 'Core/GetAPISpec' -Parameters @{} -SessionId $childSession
    $selectedConfigs = Invoke-AmpApi -BaseUri $childBase -Method 'Core/GetConfigs' -Parameters @{
        nodes = @(
            'MinecraftModule.Minecraft.ServerType',
            'MinecraftModule.Minecraft.SpecificPaperVersion',
            'MinecraftModule.Minecraft.ServerJAR',
            'MinecraftModule.Minecraft.AdditionalOpts',
            'MinecraftModule.Java.CustomOpts'
        )
    } -SessionId $childSession

    $selectedApi = [ordered]@{
        LocalFileBackupPlugin = $apiSpec.LocalFileBackupPlugin
        Core = [ordered]@{
            GetConfig = $apiSpec.Core.GetConfig
            GetConfigs = $apiSpec.Core.GetConfigs
            SetConfig = $apiSpec.Core.SetConfig
            SetConfigs = $apiSpec.Core.SetConfigs
            UpdateApplication = $apiSpec.Core.UpdateApplication
            Start = $apiSpec.Core.Start
            Stop = $apiSpec.Core.Stop
            Restart = $apiSpec.Core.Restart
        }
    }
    $result = [pscustomobject]@{
        generated_at = [DateTimeOffset]::Now.ToString('o')
        target = [pscustomobject]@{ system_id = 'game_server'; instance_id = $InstanceId }
        selected_configs = $selectedConfigs
        setting_candidates = @($candidateList)
        selected_api = [pscustomobject]$selectedApi
    }

    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.runtime'))
    if (-not $resolvedOutput.StartsWith($runtimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output must stay below the repository .runtime directory.'
    }
    $directory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $result | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
    [pscustomobject]@{ success = $true; output_path = $resolvedOutput; candidate_count = $candidateList.Count }
}
finally {
    if ($childSession) { try { Invoke-AmpApi -BaseUri $childBase -Method 'Core/Logout' -Parameters @{} -SessionId $childSession | Out-Null } catch { } }
    if ($adsSession) { try { Invoke-AmpApi -BaseUri $adsBase -Method 'Core/Logout' -Parameters @{} -SessionId $adsSession | Out-Null } catch { } }
    $password = $null
    $temporaryToken = $null
    $childSession = $null
    $adsSession = $null
    Set-Clipboard -Value ''
}
