[CmdletBinding()]
param(
    [ValidateRange(100, 999999999)]
    [int]$VmId = 301,
    [string]$Node = 'proxmox',
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.runtime\minecraft-proxmox-diagnostics.json')
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
    finally {
        Set-Clipboard -Value ''
    }
}

if (-not ('CodexVmDiagnosticsPinnedClient' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;

public static class CodexVmDiagnosticsPinnedClient {
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
$client = [CodexVmDiagnosticsPinnedClient]::Create([string]$services.services.proxmox.certificate_sha256)

function Invoke-ProxmoxGet {
    param([Parameter(Mandatory)][string]$Path)

    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $base + $Path)
    $request.Headers.TryAddWithoutValidation('Authorization', $authorization) | Out-Null
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $([int]$response.StatusCode) from $Path"
            }
            if ([string]::IsNullOrWhiteSpace($body)) { return $null }
            ($body | ConvertFrom-Json -Depth 100).data
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $request.Dispose()
    }
}

function Try-ProxmoxGet {
    param([Parameter(Mandatory)][string]$Path)
    try { Invoke-ProxmoxGet -Path $Path }
    catch { [pscustomobject]@{ unavailable = $true; reason = $_.Exception.Message } }
}

try {
    $nodeStatus = Invoke-ProxmoxGet "/nodes/$Node/status"
    $cpuModels = @(Try-ProxmoxGet "/nodes/$Node/capabilities/qemu/cpu")
    $status = Invoke-ProxmoxGet "/nodes/$Node/qemu/$VmId/status/current"
    $config = Invoke-ProxmoxGet "/nodes/$Node/qemu/$VmId/config"
    $snapshots = @(Try-ProxmoxGet "/nodes/$Node/qemu/$VmId/snapshot")
    $rrd = @(Try-ProxmoxGet "/nodes/$Node/qemu/$VmId/rrddata?timeframe=hour&cf=AVERAGE")
    $agentPing = Try-ProxmoxGet "/nodes/$Node/qemu/$VmId/agent/ping"
    $agentOs = Try-ProxmoxGet "/nodes/$Node/qemu/$VmId/agent/get-osinfo"
    $tasks = @(Try-ProxmoxGet "/nodes/$Node/tasks?typefilter=vzdump&limit=100&vmid=$VmId")
    $storageRows = @(Try-ProxmoxGet "/nodes/$Node/storage")
    $backupContent = @()
    foreach ($storage in @($storageRows | Where-Object { -not $_.unavailable -and [string]$_.content -match 'backup' })) {
        $storageId = [uri]::EscapeDataString([string]$storage.storage)
        $rows = @(Try-ProxmoxGet "/nodes/$Node/storage/$storageId/content?content=backup&vmid=$VmId")
        $backupContent += @($rows | ForEach-Object {
            if ($_.unavailable) { $_ } else {
                [pscustomobject]@{
                    storage = [string]$storage.storage
                    volume_id = $_.volid
                    created_at = $_.ctime
                    size_bytes = $_.size
                    format = $_.format
                    protected = $_.protected
                    notes = $_.notes
                }
            }
        })
    }

    $selectedConfig = [ordered]@{}
    foreach ($name in @('name','description','tags','ostype','agent','onboot','startup','boot','bios','machine','cpu','cores','sockets','memory','balloon','scsihw','net0','ide0','ide2','sata0','scsi0','virtio0')) {
        if ($config.PSObject.Properties.Name -contains $name) {
            $selectedConfig[$name] = $config.$name
        }
    }

    $result = [ordered]@{
        generated_at = [DateTimeOffset]::Now.ToString('o')
        vmid = $VmId
        node = $Node
        node_status = [ordered]@{
            cpu_model = $nodeStatus.cpuinfo.model
            cpu_count = $nodeStatus.cpuinfo.cpus
            socket_count = $nodeStatus.cpuinfo.sockets
            core_count = $nodeStatus.cpuinfo.cores
            kernel_version = $nodeStatus.kversion
            pve_version = $nodeStatus.pveversion
        }
        available_cpu_models = @($cpuModels | ForEach-Object {
            if ($_.unavailable) { $_ } else { [pscustomobject]@{ name = $_.name; vendor = $_.vendor; custom = $_.custom } }
        })
        status = [ordered]@{
            name = $status.name
            status = $status.status
            qmpstatus = $status.qmpstatus
            uptime_seconds = $status.uptime
            pid = $status.pid
            cpu_fraction = $status.cpu
            cpu_count = $status.cpus
            memory_used_bytes = $status.mem
            memory_max_bytes = $status.maxmem
            disk_used_bytes = $status.disk
            disk_max_bytes = $status.maxdisk
            network_in_bytes = $status.netin
            network_out_bytes = $status.netout
            disk_read_bytes = $status.diskread
            disk_write_bytes = $status.diskwrite
            ha_state = $status.ha.state
        }
        config = $selectedConfig
        snapshots = @($snapshots | ForEach-Object {
            if ($_.unavailable) { $_ } else {
                [pscustomobject]@{ name = $_.name; description = $_.description; snaptime = $_.snaptime; vmstate = $_.vmstate; parent = $_.parent }
            }
        })
        rrd_hour = @($rrd | ForEach-Object {
            if ($_.unavailable) { $_ } else {
                [pscustomobject]@{ time = $_.time; cpu = $_.cpu; mem = $_.mem; maxmem = $_.maxmem; netin = $_.netin; netout = $_.netout; diskread = $_.diskread; diskwrite = $_.diskwrite }
            }
        })
        guest_agent = [ordered]@{ ping = $agentPing; os = $agentOs }
        recent_backup_tasks = @($tasks | ForEach-Object {
            if ($_.unavailable) { $_ } else {
                [pscustomobject]@{ upid = $_.upid; type = $_.type; id = $_.id; status = $_.status; exitstatus = $_.exitstatus; starttime = $_.starttime; endtime = $_.endtime; user = $_.user }
            }
        })
        backup_content = @($backupContent)
    }

    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.runtime'))
    if (-not $resolvedOutput.StartsWith($runtimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output must stay below the repository .runtime directory.'
    }
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    [pscustomobject]$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
    [pscustomobject]@{ success = $true; output_path = $resolvedOutput; status = $result.status; config = $result.config }
}
finally {
    $authorization = $null
    $token = $null
    Set-Clipboard -Value ''
    $client.Dispose()
}
