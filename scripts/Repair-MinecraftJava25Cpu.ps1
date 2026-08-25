[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidateRange(100, 999999999)]
    [int]$VmId = 301,
    [string]$Node = 'proxmox',
    [string]$TargetCpu = 'x86-64-v3',
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.runtime\minecraft-java25-cpu-repair.json')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'CodexAdmin.Common.psm1') -Force
$services = Get-Content -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\services.json') -Raw | ConvertFrom-Json
$profiles = Get-Content -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\access-profiles.json') -Raw | ConvertFrom-Json
$profile = @($profiles.profiles | Where-Object id -eq 'proxmox-api-admin') | Select-Object -First 1
if (-not $profile) { throw 'The Proxmox API access profile is unavailable.' }
$store = (Resolve-Path (Join-Path $repositoryRoot 'apps\secret-ui\backend\SecretUiStore.ps1')).Path

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

if (-not ('CodexMinecraftCpuRepairPinnedClient' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;

public static class CodexMinecraftCpuRepairPinnedClient {
    public static HttpClient Create(string expectedSha256) {
        var handler = new HttpClientHandler();
        handler.CookieContainer = new CookieContainer();
        handler.ServerCertificateCustomValidationCallback = (message, cert, chain, errors) => {
            if (cert == null) return false;
            using (var sha = SHA256.Create()) {
                var actual = BitConverter.ToString(sha.ComputeHash(cert.RawData)).Replace("-", "");
                return String.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase);
            }
        };
        return new HttpClient(handler, true);
    }
}
'@
}

$token = Get-VaultClipboardValue ([string]$profile.credential_ref)
$authorization = "PVEAPIToken=$([string]$profile.identity)=$token"
$token = $null
$base = ([string]$services.services.proxmox.base_url).TrimEnd('/') + '/api2/json'
$client = [CodexMinecraftCpuRepairPinnedClient]::Create([string]$services.services.proxmox.certificate_sha256)

function Invoke-ProxmoxRequest {
    param(
        [Parameter(Mandatory)][Net.Http.HttpMethod]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body,
        [switch]$FormEncoded
    )
    $request = [Net.Http.HttpRequestMessage]::new($Method, $base + $Path)
    $request.Headers.TryAddWithoutValidation('Authorization', $authorization) | Out-Null
    if ($null -ne $Body) {
        if ($FormEncoded) {
            $pairs = [Collections.Generic.List[Collections.Generic.KeyValuePair[string,string]]]::new()
            foreach ($entry in $Body.GetEnumerator()) {
                $pairs.Add([Collections.Generic.KeyValuePair[string,string]]::new([string]$entry.Key, [string]$entry.Value))
            }
            $request.Content = [Net.Http.FormUrlEncodedContent]::new($pairs)
        }
        else {
            $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 20 -Compress), [Text.Encoding]::UTF8, 'application/json')
        }
    }
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $([int]$response.StatusCode) from $Path."
            }
            if ([string]::IsNullOrWhiteSpace($responseBody)) { return $null }
            ($responseBody | ConvertFrom-Json -Depth 100).data
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose() }
}

function Get-VmStatus {
    Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Get) -Path "/nodes/$Node/qemu/$VmId/status/current"
}

function Wait-VmState {
    param([Parameter(Mandatory)][string]$State, [Parameter(Mandatory)][DateTimeOffset]$Deadline)
    do {
        Start-Sleep -Seconds 2
        $status = Get-VmStatus
        if ([string]$status.status -eq $State) { return $status }
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    throw "VM $VmId did not reach state '$State' before the safety deadline."
}

function Wait-GuestAgent {
    param([Parameter(Mandatory)][DateTimeOffset]$Deadline)
    do {
        Start-Sleep -Seconds 3
        try {
            $osInfo = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Get) -Path "/nodes/$Node/qemu/$VmId/agent/get-osinfo"
            if ($null -ne $osInfo) { return $true }
        }
        catch { }
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    throw "VM $VmId guest agent did not become ready before the safety deadline."
}

function Test-Java25 {
    $script = "ulimit -c 0; i=0; while [ `$i -lt 90 ]; do docker ps --format '{{.Names}}' | grep -Fxq AMP_MineMineVine01 && break; i=`$((i+1)); sleep 2; done; docker exec AMP_MineMineVine01 /usr/lib/jvm/temurin-25-jdk-amd64/bin/java -version"
    $started = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Post) `
        -Path "/nodes/$Node/qemu/$VmId/agent/exec" `
        -Body @{ command = @('/bin/sh', '-lc', $script) }
    $guestProcessId = [int]$started.pid
    if ($guestProcessId -le 0) { throw 'Java verification did not return a guest process identifier.' }
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(4)
    do {
        Start-Sleep -Seconds 1
        $status = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Get) `
            -Path "/nodes/$Node/qemu/$VmId/agent/exec-status?pid=$guestProcessId"
    } while (-not $status.exited -and [DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $status.exited) { throw 'Java verification exceeded the safety deadline.' }
    [pscustomobject]@{
        exit_code = [int]$status.exitcode
        version_detected = ([string]$status.'err-data' -match 'openjdk version "25\.') -or `
            ([string]$status.'out-data' -match 'openjdk version "25\.')
    }
}

if (-not $Apply) { throw 'Use -Apply only after an explicitly authorized repair request.' }

$originalCpu = $null
$cpuChanged = $false
$rollbackAttempted = $false
$rollbackSucceeded = $false
$result = [ordered]@{
    generated_at = [DateTimeOffset]::Now.ToString('o')
    target = [ordered]@{ system_id = 'game_server'; vmid = $VmId; node = $Node }
    before = $null
    after = $null
    result = 'failed'
    rollback = 'not_required'
    failure = $null
}

try {
    $config = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Get) -Path "/nodes/$Node/qemu/$VmId/config"
    $status = Get-VmStatus
    $originalCpu = [string]$config.cpu
    $result.before = [ordered]@{ cpu = $originalCpu; vm_status = [string]$status.status }
    if ($originalCpu -ne 'x86-64-v2-AES') { throw "Unexpected current CPU type '$originalCpu'." }
    if ([string]$status.status -ne 'running') { throw "Unexpected VM state '$($status.status)'." }

    Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Put) -Path "/nodes/$Node/qemu/$VmId/config" -Body @{ cpu = $TargetCpu } -FormEncoded | Out-Null
    $configured = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Get) -Path "/nodes/$Node/qemu/$VmId/config"
    if ([string]$configured.cpu -ne $TargetCpu) { throw 'Proxmox did not retain the requested CPU type.' }
    $cpuChanged = $true

    Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Post) -Path "/nodes/$Node/qemu/$VmId/status/shutdown" -Body @{} | Out-Null
    Wait-VmState -State 'stopped' -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(3)) | Out-Null
    Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Post) -Path "/nodes/$Node/qemu/$VmId/status/start" -Body @{} | Out-Null
    Wait-VmState -State 'running' -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(2)) | Out-Null
    Wait-GuestAgent -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(3)) | Out-Null
    Start-Sleep -Seconds 15
    $java = Test-Java25
    if ($java.exit_code -ne 0 -or -not $java.version_detected) { throw 'Java 25 still failed its direct startup verification.' }

    $afterConfig = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Get) -Path "/nodes/$Node/qemu/$VmId/config"
    $afterStatus = Get-VmStatus
    $result.after = [ordered]@{
        cpu = [string]$afterConfig.cpu
        vm_status = [string]$afterStatus.status
        java25_exit_code = $java.exit_code
        java25_version_detected = $java.version_detected
    }
    $result.result = 'succeeded'
}
catch {
    $result.failure = $_.Exception.Message
    if ($cpuChanged -and $originalCpu) {
        $rollbackAttempted = $true
        try {
            $currentStatus = Get-VmStatus
            if ([string]$currentStatus.status -eq 'running') {
                Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Post) -Path "/nodes/$Node/qemu/$VmId/status/shutdown" -Body @{} | Out-Null
                Wait-VmState -State 'stopped' -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(3)) | Out-Null
            }
            Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Put) -Path "/nodes/$Node/qemu/$VmId/config" -Body @{ cpu = $originalCpu } -FormEncoded | Out-Null
            $restored = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Get) -Path "/nodes/$Node/qemu/$VmId/config"
            if ([string]$restored.cpu -ne $originalCpu) { throw 'Original CPU type was not restored.' }
            Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Post) -Path "/nodes/$Node/qemu/$VmId/status/start" -Body @{} | Out-Null
            Wait-VmState -State 'running' -Deadline ([DateTimeOffset]::UtcNow.AddMinutes(2)) | Out-Null
            $rollbackSucceeded = $true
        }
        catch {
            $result.failure += " Rollback also failed: $($_.Exception.Message)"
        }
    }
    $result.rollback = if ($rollbackAttempted -and $rollbackSucceeded) { 'cpu_restored_and_vm_started' } elseif ($rollbackAttempted) { 'failed' } else { 'not_required' }
}
finally {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.runtime'))
    if (-not $resolvedOutput.StartsWith($runtimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output must stay below the repository .runtime directory.'
    }
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    [pscustomobject]$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
    $authorization = $null
    $token = $null
    if ($client) { $client.Dispose() }
}

[pscustomobject]$result
