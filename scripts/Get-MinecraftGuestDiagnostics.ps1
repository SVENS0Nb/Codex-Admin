[CmdletBinding()]
param(
    [ValidateRange(100, 999999999)]
    [int]$VmId = 301,
    [string]$Node = 'proxmox',
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.runtime\minecraft-guest-diagnostics.json'),
    [switch]$NoPersist
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

function ConvertTo-SafeText {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return $null }
    $safe = $Value
    $safe = $safe -replace '(?i)(authorization\s*[:=]\s*)([^\s,;]+)', '$1<redacted>'
    $safe = $safe -replace '(?i)((?:password|passwd|token|session(?:id)?|secret|api[_ -]?key|license.?key|licence.?key)\s*[:=]\s*)([^\s,;]+)', '$1<redacted>'
    $safe = $safe -replace '(?i)((?:password|passwd|token|session(?:id)?|secret|api[_ -]?key|license.?key|licence.?key)\s+(?:to|is)\s+)(?:"[^"]*"|''[^'']*''|[^\r\n]+)', '$1<redacted>'
    $safe = $safe -replace '(?i)(-----BEGIN [A-Z ]*PRIVATE KEY-----)[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----)', '$1<redacted>$2'
    $safe
}

if (-not ('CodexGuestDiagnosticsPinnedClient' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;

public static class CodexGuestDiagnosticsPinnedClient {
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
$client = [CodexGuestDiagnosticsPinnedClient]::Create([string]$services.services.proxmox.certificate_sha256)

function Invoke-ProxmoxRequest {
    param(
        [Parameter(Mandatory)][Net.Http.HttpMethod]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body
    )
    $request = [Net.Http.HttpRequestMessage]::new($Method, $base + $Path)
    $request.Headers.TryAddWithoutValidation('Authorization', $authorization) | Out-Null
    if ($null -ne $Body) {
        $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 20 -Compress), [Text.Encoding]::UTF8, 'application/json')
    }
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                $safeError = ConvertTo-SafeText $responseBody
                if ($safeError.Length -gt 1000) { $safeError = $safeError.Substring(0, 1000) }
                throw "HTTP $([int]$response.StatusCode) from ${Path}: $safeError"
            }
            if ([string]::IsNullOrWhiteSpace($responseBody)) { return $null }
            ($responseBody | ConvertFrom-Json -Depth 100).data
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose() }
}

function Invoke-GuestReadCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script
    )

    $started = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Post) `
        -Path "/nodes/$Node/qemu/$VmId/agent/exec" `
        -Body @{ command = @('/bin/sh', '-lc', $Script) }
    $guestProcessId = [int]$started.pid
    if ($guestProcessId -le 0) { throw "Guest command '$Name' did not return a process identifier." }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        $status = Invoke-ProxmoxRequest -Method ([Net.Http.HttpMethod]::Get) `
            -Path "/nodes/$Node/qemu/$VmId/agent/exec-status?pid=$guestProcessId"
    } while (-not $status.exited -and [DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $status.exited) { throw "Guest command '$Name' exceeded the diagnostic time limit." }
    if (-not $status.PSObject.Properties['exitcode']) { throw "Guest command '$Name' did not return an exit code." }
    [pscustomobject]@{
        name = $Name
        exit_code = [int]$status.exitcode
        stdout = if ($status.PSObject.Properties['out-data']) { ConvertTo-SafeText ([string]$status.'out-data') } else { '' }
        stderr = if ($status.PSObject.Properties['err-data']) { ConvertTo-SafeText ([string]$status.'err-data') } else { '' }
    }
}

$commands = [ordered]@{
    host = @'
printf 'HOSTNAME\t'; hostname
printf 'KERNEL\t'; uname -sr
printf 'UPTIME\t'; uptime
printf 'MEMORY\n'; free -h
printf 'FILESYSTEMS\n'; df -h / /home 2>/dev/null
'@
    services = @'
printf 'AMP SERVICES\n'
systemctl list-units --type=service --all --no-legend --no-pager | grep -Ei 'amp|docker|qemu-guest' || true
printf 'LISTENERS\n'
ss -lntp | grep -E ':(22|2223|2224|8080|8081|25565)[[:space:]]' || true
'@
    containers = @'
printf 'CONTAINERS\n'
docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1
printf 'TARGET STATE\n'
target=$(docker ps -a --format '{{.Names}}' | grep -i 'MineMineVine' | head -n 1)
if [ -n "$target" ]; then
  docker inspect --format '{{.Name}} status={{.State.Status}} running={{.State.Running}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}} restart={{.RestartCount}} network={{.HostConfig.NetworkMode}} memory={{.HostConfig.Memory}} nanocpus={{.HostConfig.NanoCpus}} binds={{json .HostConfig.Binds}}' "$target"
fi
'@
    amp_files = @'
root=/home/amp/.ampdata/instances/MineMineVine01
printf 'INSTANCE PATH\n'
find "$root" -maxdepth 2 -mindepth 1 -printf '%y\t%TY-%Tm-%TdT%TH:%TM:%TSZ\t%s\t%p\n' 2>/dev/null | sort | head -n 300
printf 'AMP LOG FILES\n'
find "$root/AMP_Logs" -maxdepth 1 -type f -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -nr | head -n 20
'@
    amp_log_tail = @'
root=/home/amp/.ampdata/instances/MineMineVine01
latest=$(find "$root/AMP_Logs" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)
if [ -n "$latest" ]; then
  printf 'LATEST AMP LOG\t%s\n' "$latest"
  tail -n 350 "$latest"
else
  printf 'LATEST AMP LOG\tnot found\n'
fi
'@
    argument_source = @'
root=/home/amp/.ampdata/instances/MineMineVine01
printf 'CONFIG MATCHES\n'
grep -RIn --include='*.kvp' --include='*.conf' -- '--log-strip-color' "$root" 2>/dev/null || true
printf 'MODULE BINARY MATCHES\n'
find "$root/Plugins/MinecraftModule" -maxdepth 2 -type f -print0 2>/dev/null | xargs -0 -r strings 2>/dev/null | grep -F -- '--log-strip-color' | head -n 20 || true
printf 'SELECTED MINECRAFT SETTINGS\n'
grep -E 'MinecraftModule\.(Minecraft|Java)\..*(Args|Argument|Flag|ServerType|Version|Jar|Heap)' "$root/MinecraftModule.kvp" 2>/dev/null || true
printf 'SELECTED KVP STRINGS\n'
strings -n 3 "$root/MinecraftModule.kvp" 2>/dev/null | nl -ba | grep -Ei -B 2 -A 3 'Paper|ServerType|Version|ServerJar|Argument|Flag|Color|Heap' | head -n 240 || true
'@
    container_log_tail = @'
target=$(docker ps -a --format '{{.Names}}' | grep -i 'MineMineVine' | head -n 1)
if [ -n "$target" ]; then
  printf 'CONTAINER LOG\t%s\n' "$target"
  docker logs --tail 350 "$target" 2>&1
else
  printf 'CONTAINER LOG\tnot found\n'
fi
'@
    minecraft_crash_context = @'
root=/home/amp/.ampdata/instances/MineMineVine01/Minecraft
printf 'MINECRAFT LOG FILES\n'
find "$root/logs" -maxdepth 1 -type f -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -nr | head -n 20
if [ -f "$root/logs/latest.log" ]; then
  printf 'LATEST MINECRAFT LOG\n'
  tail -n 300 "$root/logs/latest.log"
fi
printf 'JVM CRASH FILES\n'
find "$root" -maxdepth 2 -type f \( -name 'hs_err_pid*.log' -o -name 'replay_pid*.log' -o -name 'core' \) -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -nr | head -n 20
if [ -f "$root/core" ]; then
  printf 'CORE TYPE\n'
  file "$root/core" 2>/dev/null || true
fi
printf 'RECENT KERNEL FAULTS\n'
journalctl -k --since '-15 minutes' --no-pager 2>/dev/null | grep -Ei 'segfault|trap|oom|killed process|java|core' | tail -n 100 || true
'@
    java_cpu_context = @'
target=$(docker ps -a --format '{{.Names}}' | grep -i 'MineMineVine' | head -n 1)
printf 'HOST CPU\n'
lscpu 2>/dev/null | grep -E '^(Architecture|Model name|CPU op-mode|Flags|Virtualization|Hypervisor vendor):' || true
if [ -n "$target" ]; then
  printf 'CONTAINER JAVA RUNTIMES\n'
  docker exec "$target" /bin/sh -lc 'for java in /usr/lib/jvm/*/bin/java; do [ -x "$java" ] || continue; printf "PATH\t%s\n" "$java"; "$java" -version 2>&1 | head -n 3; done' 2>&1
  printf 'JAVA 25 PACKAGE\n'
  docker exec "$target" /bin/sh -lc "dpkg-query -W -f='\${Package}\t\${Version}\n' 'temurin-25-*' 2>/dev/null || true" 2>&1
fi
'@
    java25_flag_probe = @'
target=$(docker ps -a --format '{{.Names}}' | grep -i 'MineMineVine' | head -n 1)
if [ -n "$target" ]; then
  docker exec "$target" /bin/sh -lc '
    ulimit -c 0
    java=/usr/lib/jvm/temurin-25-jdk-amd64/bin/java
    for label in interpreter no_avx no_shared_archive; do
      printf "PROBE\t%s\n" "$label"
      case "$label" in
        interpreter) "$java" -Xint -version ;;
        no_avx) "$java" -XX:UseAVX=0 -version ;;
        no_shared_archive) "$java" -Xshare:off -version ;;
      esac
      printf "EXIT\t%s\n" "$?"
    done
  ' 2>&1
fi
'@
    minecraft_runtime_config = @'
root=/home/amp/.ampdata/instances/MineMineVine01/Minecraft
printf 'SELECTED SERVER PROPERTIES\n'
grep -E '^(white-list|enforce-whitelist|online-mode|max-players|server-port|enable-rcon|enable-query)=' "$root/server.properties" 2>/dev/null || true
printf 'WHITELIST FILES\n'
find "$root" -maxdepth 1 -type f -name 'whitelist.json*' -printf '%T@\t%s\t%f\n' 2>/dev/null | sort -nr
'@
}

try {
    $results = @()
    foreach ($command in $commands.GetEnumerator()) {
        try {
            $results += Invoke-GuestReadCommand -Name $command.Key -Script $command.Value
        }
        catch {
            $results += [pscustomobject]@{ name = $command.Key; unavailable = $true; reason = ConvertTo-SafeText $_.Exception.Message }
        }
    }
    $containerResult = @($results | Where-Object name -eq 'containers' | Select-Object -First 1)
    $containerText = if ($containerResult.Count -eq 1 -and $containerResult[0].PSObject.Properties['stdout']) { [string]$containerResult[0].stdout } else { '' }
    $containerState = [regex]::Match(
        $containerText,
        '(?im)\bstatus=(?<status>\S+)\s+running=(?<running>true|false)\s+exit=(?<exit>\d+)\s+oom=(?<oom>true|false)'
    )
    $crashResult = @($results | Where-Object name -eq 'minecraft_crash_context' | Select-Object -First 1)
    $crashText = if ($crashResult.Count -eq 1 -and $crashResult[0].PSObject.Properties['stdout']) { [string]$crashResult[0].stdout } else { '' }
    $recentKernelSection = if ($crashText -match '(?s)RECENT KERNEL FAULTS\s*(?<section>.*)$') { [string]$Matches.section } else { '' }
    $recentKernelFaults = @($recentKernelSection -split '\r?\n' | Where-Object {
        $_ -match '(?i)segfault|trap|oom|killed process|java|core'
    }).Count
    $signals = [pscustomobject]@{
        container_state_observed = $containerState.Success
        container_not_running = $containerState.Success -and $containerState.Groups['running'].Value -ne 'true'
        container_oom_killed = $containerState.Success -and $containerState.Groups['oom'].Value -eq 'true'
        container_exit_code = if ($containerState.Success) { [int]$containerState.Groups['exit'].Value } else { 0 }
        recent_kernel_faults = $recentKernelFaults
        recent_application_errors = 0
    }
    $unavailableResults = @($results | Where-Object {
        $_.PSObject.Properties['unavailable'] -and [bool]$_.unavailable
    })
    $output = [pscustomobject]@{
        generated_at = [DateTimeOffset]::Now.ToString('o')
        system_id = 'game_server'
        vmid = $VmId
        results = $results
    }
    $resolvedOutput = $null
    if (-not $NoPersist) {
        $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
        $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.runtime'))
        if (-not $resolvedOutput.StartsWith($runtimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Output must stay below the repository .runtime directory.'
        }
        $outputDirectory = Split-Path -Parent $resolvedOutput
        if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $output | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
    }
    [pscustomobject]@{
        success = $unavailableResults.Count -eq 0
        generated_at = $output.generated_at
        output_path = $resolvedOutput
        command_status = @($results | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.name
                exit_code = if ($_.PSObject.Properties['exit_code']) { [int]$_.exit_code } else { $null }
                unavailable = if ($_.PSObject.Properties['unavailable']) { [bool]$_.unavailable } else { $false }
                failure_reason = if ($_.PSObject.Properties['reason']) {
                    $safeReason = ConvertTo-SafeText ([string]$_.reason)
                    if ($safeReason.Length -gt 300) { $safeReason = $safeReason.Substring(0, 300) }
                    $safeReason
                }
                else { $null }
            }
        })
        signals = $signals
    }
}
finally {
    $authorization = $null
    $token = $null
    Set-Clipboard -Value ''
    $client.Dispose()
}
