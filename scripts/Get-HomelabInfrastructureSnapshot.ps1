[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.runtime\infrastructure-snapshot.json')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'CodexAdmin.Common.psm1') -Force
$inventory = Get-Content -Raw -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\services.json') | ConvertFrom-Json
$access = Get-Content -Raw -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\access-profiles.json') | ConvertFrom-Json
$store = (Resolve-Path (Join-Path $repositoryRoot 'apps\secret-ui\backend\SecretUiStore.ps1')).Path
$python = (Get-Command python.exe -ErrorAction Stop).Source
$sshHelper = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-SshCommand.py')).Path
$identity = Join-Path $env:USERPROFILE '.ssh\codex_admin_ed25519'
$knownHosts = Join-Path $env:USERPROFILE '.ssh\known_hosts'

function Get-AccessProfile {
    param([Parameter(Mandatory)][string]$Id)

    $profile = @($access.profiles | Where-Object id -eq $Id) | Select-Object -First 1
    if (-not $profile) { throw "Access profile '$Id' is not configured." }
    $profile
}

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

if (-not ('CodexInventoryPinnedClient' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;

public static class CodexInventoryPinnedClient {
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

function Invoke-JsonGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$HeaderName,
        [Parameter(Mandatory)][string]$HeaderValue,
        [string]$CertificateSha256
    )

    $client = if ($CertificateSha256) {
        [CodexInventoryPinnedClient]::Create($CertificateSha256)
    } else {
        [Net.Http.HttpClient]::new()
    }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    try {
        $request.Headers.TryAddWithoutValidation($HeaderName, $HeaderValue) | Out-Null
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $([int]$response.StatusCode) from $(([uri]$Uri).AbsolutePath)"
            }
            if ([string]::IsNullOrWhiteSpace($body)) { return $null }
            $body | ConvertFrom-Json -Depth 100
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $request.Dispose()
        $client.Dispose()
    }
}

function Invoke-KeySsh {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Command,
        [int]$Port = 22
    )

    $result = & $python $sshHelper `
        --host $HostName `
        --port $Port `
        --user $UserName `
        --identity $identity `
        --known-hosts $knownHosts `
        --command $Command 2>$null
    if ($LASTEXITCODE -ne 0) { throw "SSH command failed on ${HostName}:$Port." }
    (@($result) -join "`n").Trim()
}

function ConvertFrom-JsonOrNull {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { $Text | ConvertFrom-Json -Depth 100 } catch { $null }
}

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and [string]$property.Value -ne '') {
            return $property.Value
        }
    }
    $null
}

function Get-ApiRows {
    param($Response)

    if ($null -eq $Response) { return @() }
    if ($Response.PSObject.Properties['data']) { return @($Response.data) }
    @($Response)
}

function Get-ProxmoxSnapshot {
    $service = $inventory.services.proxmox
    $profile = Get-AccessProfile 'proxmox-api-admin'
    $token = Get-VaultClipboardValue ([string]$profile.credential_ref)
    $authorization = "PVEAPIToken=$([string]$profile.identity)=$token"
    $base = ([string]$service.base_url).TrimEnd('/') + '/api2/json'
    try {
        $get = {
            param([string]$Path)
            Invoke-JsonGet -Uri ($base + $Path) -HeaderName 'Authorization' `
                -HeaderValue $authorization -CertificateSha256 ([string]$service.certificate_sha256)
        }

        $version = (& $get '/version').data
        $nodes = @((& $get '/nodes').data)
        $resources = @((& $get '/cluster/resources').data)
        $cluster = @((& $get '/cluster/status').data)
        $storageConfiguration = @((& $get '/storage').data | ForEach-Object {
            [pscustomobject]@{
                storage = [string]$_.storage
                type = [string]$_.type
                content = [string]$_.content
                path = [string]$_.path
                server = [string]$_.server
                share = [string]$_.share
                nodes = [string]$_.nodes
                disabled = [bool]$_.disable
            }
        })
        $guests = @($resources | Where-Object type -in @('qemu', 'lxc') | ForEach-Object {
            $guest = $_
            $configPath = "/nodes/$($guest.node)/$($guest.type)/$($guest.vmid)/config"
            $config = $null
            try { $config = (& $get $configPath).data } catch { }
            $attachments = [ordered]@{}
            if ($config) {
                foreach ($property in $config.PSObject.Properties) {
                    if ($property.Name -match '^(net\d+|ide\d+|sata\d+|scsi\d+|virtio\d+|efidisk\d+|tpmstate\d+|mp\d+|rootfs)$') {
                        $attachments[$property.Name] = [string]$property.Value
                    }
                }
            }

            $addresses = @()
            try {
                if ($guest.type -eq 'qemu' -and $guest.status -eq 'running') {
                    $agent = (& $get "/nodes/$($guest.node)/qemu/$($guest.vmid)/agent/network-get-interfaces").data.result
                    $addresses = @($agent | ForEach-Object {
                        $interface = $_
                        @($interface.'ip-addresses' | Where-Object {
                            $_.'ip-address' -and $_.'ip-address' -notin @('127.0.0.1', '::1')
                        } | ForEach-Object {
                            [pscustomobject]@{
                                interface = [string]$interface.name
                                address = [string]$_.'ip-address'
                                prefix = [int]$_.'prefix'
                                family = [string]$_.'ip-address-type'
                                mac = [string]$interface.'hardware-address'
                            }
                        })
                    })
                }
                elseif ($guest.type -eq 'lxc' -and $guest.status -eq 'running') {
                    $containerInterfaces = @((& $get "/nodes/$($guest.node)/lxc/$($guest.vmid)/interfaces").data)
                    $addresses = @($containerInterfaces | ForEach-Object {
                        $interface = $_
                        @($interface.inet | ForEach-Object {
                            if ($_ -and $_ -notmatch '^127\.') {
                                $parts = [string]$_ -split '/'
                                [pscustomobject]@{
                                    interface = [string]$interface.name
                                    address = $parts[0]
                                    prefix = if ($parts.Count -gt 1) { [int]$parts[1] } else { $null }
                                    family = 'ipv4'
                                    mac = [string]$interface.hwaddr
                                }
                            }
                        })
                    })
                }
            } catch { }

            [pscustomobject]@{
                vmid = [int]$guest.vmid
                type = [string]$guest.type
                node = [string]$guest.node
                name = [string]$guest.name
                status = [string]$guest.status
                template = [bool]$guest.template
                tags = [string]$guest.tags
                pool = [string]$guest.pool
                cpu_count = [int]$guest.maxcpu
                memory_bytes = [long]$guest.maxmem
                disk_bytes = [long]$guest.maxdisk
                uptime_seconds = [long]$guest.uptime
                os_type = if ($config) { [string]$config.ostype } else { $null }
                on_boot = if ($config) { [bool]([int]$config.onboot) } else { $null }
                guest_agent = if ($config) { [string]$config.agent } else { $null }
                unprivileged = if ($guest.type -eq 'lxc' -and $config) { [bool]([int]$config.unprivileged) } else { $null }
                attachments = $attachments
                addresses = @($addresses)
            }
        })

        $nodeDetails = @($nodes | ForEach-Object {
            $node = $_
            $networks = @()
            $storage = @()
            try {
                $networks = @((& $get "/nodes/$($node.node)/network").data | ForEach-Object {
                    [pscustomobject]@{
                        interface = [string]$_.iface
                        type = [string]$_.type
                        address = [string]$_.address
                        cidr = [string]$_.cidr
                        bridge_ports = [string]$_.bridge_ports
                        vlan_aware = [bool]$_.bridge_vlan_aware
                        active = [bool]$_.active
                        autostart = [bool]$_.autostart
                    }
                })
            } catch { }
            try {
                $storage = @((& $get "/nodes/$($node.node)/storage").data | ForEach-Object {
                    [pscustomobject]@{
                        storage = [string]$_.storage
                        type = [string]$_.type
                        content = [string]$_.content
                        enabled = [bool]$_.enabled
                        active = [bool]$_.active
                        shared = [bool]$_.shared
                        total_bytes = [long]$_.total
                        used_bytes = [long]$_.used
                        available_bytes = [long]$_.avail
                    }
                })
            } catch { }
            [pscustomobject]@{
                name = [string]$node.node
                status = [string]$node.status
                cpu_count = [int]$node.maxcpu
                memory_bytes = [long]$node.maxmem
                disk_bytes = [long]$node.maxdisk
                uptime_seconds = [long]$node.uptime
                networks = @($networks)
                storage = @($storage)
            }
        })

        [pscustomobject]@{
            version = [string]$version.version
            release = [string]$version.release
            repository_id = [string]$version.repoid
            cluster = @($cluster | ForEach-Object {
                [pscustomobject]@{
                    type = [string]$_.type
                    id = [string]$_.id
                    name = [string]$_.name
                    node_id = $_.nodeid
                    online = $_.online
                    local = $_.local
                }
            })
            nodes = @($nodeDetails)
            storage_configuration = @($storageConfiguration)
            guests = @($guests)
        }
    }
    finally {
        $authorization = $null
        $token = $null
        Set-Clipboard -Value ''
    }
}

function Get-HomeAssistantSnapshot {
    $service = $inventory.services.home_assistant
    $profile = Get-AccessProfile 'home-assistant-api-admin'
    $token = Get-VaultClipboardValue ([string]$profile.credential_ref)
    $authorization = "Bearer $token"
    $base = ([string]$service.base_url).TrimEnd('/')
    try {
        $config = Invoke-JsonGet -Uri "$base/api/config" -HeaderName 'Authorization' -HeaderValue $authorization
        $services = @(Invoke-JsonGet -Uri "$base/api/services" -HeaderName 'Authorization' -HeaderValue $authorization)
        $states = @(Invoke-JsonGet -Uri "$base/api/states" -HeaderName 'Authorization' -HeaderValue $authorization)
        $domainCounts = @($states | Group-Object { ([string]$_.entity_id -split '\.', 2)[0] } | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ domain = [string]$_.Name; entity_count = [int]$_.Count }
        })
        $serviceDomains = @($services | Sort-Object domain | ForEach-Object {
            [pscustomobject]@{
                domain = [string]$_.domain
                services = @($_.services.PSObject.Properties.Name | Sort-Object)
            }
        })

        $hostInfo = ConvertFrom-JsonOrNull (Invoke-KeySsh -HostName ([uri]$service.ssh_url).Host `
            -Port ([uri]$service.ssh_url).Port -UserName ([string]$service.ssh_user) -Command 'ha host info --raw-json')
        $supervisorInfo = ConvertFrom-JsonOrNull (Invoke-KeySsh -HostName ([uri]$service.ssh_url).Host `
            -Port ([uri]$service.ssh_url).Port -UserName ([string]$service.ssh_user) -Command 'ha supervisor info --raw-json')
        $addons = ConvertFrom-JsonOrNull (Invoke-KeySsh -HostName ([uri]$service.ssh_url).Host `
            -Port ([uri]$service.ssh_url).Port -UserName ([string]$service.ssh_user) -Command 'ha addons list --raw-json')
        $networkInfo = ConvertFrom-JsonOrNull (Invoke-KeySsh -HostName ([uri]$service.ssh_url).Host `
            -Port ([uri]$service.ssh_url).Port -UserName ([string]$service.ssh_user) -Command 'ha network info --raw-json')

        [pscustomobject]@{
            version = [string]$config.version
            installation_type = [string]$config.installation_type
            timezone = [string]$config.time_zone
            internal_url = [string]$config.internal_url
            external_url = [string]$config.external_url
            state = [string]$config.state
            safe_mode = [bool]$config.safe_mode
            components = @($config.components | Sort-Object)
            entity_domains = @($domainCounts)
            service_domains = @($serviceDomains)
            host = $hostInfo.data
            supervisor = $supervisorInfo.data
            addons = @($addons.data.addons | ForEach-Object {
                [pscustomobject]@{
                    slug = [string]$_.slug
                    name = [string]$_.name
                    version = [string]$_.version
                    state = [string]$_.state
                    update_available = [bool]$_.update_available
                    repository = [string]$_.repository
                }
            })
            network = $networkInfo.data
        }
    }
    finally {
        $authorization = $null
        $token = $null
        Set-Clipboard -Value ''
    }
}

function Get-ReverseProxySnapshot {
    $service = $inventory.services.reverse_proxy
    $uri = [uri]$service.ssh_url
    $hostName = Invoke-KeySsh -HostName $uri.Host -Port $uri.Port -UserName ([string]$service.ssh_user) -Command 'hostname'
    $kernel = Invoke-KeySsh -HostName $uri.Host -Port $uri.Port -UserName ([string]$service.ssh_user) -Command 'uname -sr'
    $containers = @()
    try {
        $dockerRaw = Invoke-KeySsh -HostName $uri.Host -Port $uri.Port -UserName ([string]$service.ssh_user) `
            -Command "sudo -n docker ps --format '{{json .}}'"
        $containers = @($dockerRaw -split "`n" | Where-Object { $_ } | ForEach-Object {
            $row = $_ | ConvertFrom-Json
            [pscustomobject]@{
                name = [string]$row.Names
                image = [string]$row.Image
                state = [string]$row.State
                status = [string]$row.Status
                ports = [string]$row.Ports
                networks = [string]$row.Networks
            }
        })
    } catch { }

    $runningServices = @()
    try {
        $serviceRaw = Invoke-KeySsh -HostName $uri.Host -Port $uri.Port -UserName ([string]$service.ssh_user) `
            -Command 'systemctl list-units --type=service --state=running --no-legend --no-pager --plain'
        $runningServices = @($serviceRaw -split "`n" | ForEach-Object {
            if ($_ -match '^\s*([^\s]+\.service)\s+loaded\s+active\s+running\s+(.+)$') {
                [pscustomobject]@{ unit = $Matches[1]; description = $Matches[2].Trim() }
            }
        } | Where-Object { $_ })
    } catch { }

    $proxyCommand = @'
sudo -n sh -c 'for f in /data/nginx/proxy_host/*.conf; do [ -f "$f" ] || continue; printf "FILE\t%s\n" "$(basename "$f")"; grep -E "server_name|forward_scheme|set [$]server|set [$]port" "$f" || true; done'
'@
    $proxyRaw = Invoke-KeySsh -HostName $uri.Host -Port $uri.Port -UserName ([string]$service.ssh_user) -Command $proxyCommand
    $proxyHosts = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in @($proxyRaw -split "`n")) {
        if ($line -match '^FILE\t(.+)$') {
            if ($current) { $proxyHosts.Add([pscustomobject]$current) }
            $current = [ordered]@{ config = $Matches[1]; domains = @(); scheme = $null; upstream = $null; port = $null }
            continue
        }
        if (-not $current) { continue }
        if ($line -match '^\s*server_name\s+(.+?);\s*$') {
            $current.domains = @($Matches[1] -split '\s+' | Where-Object { $_ -and $_ -ne '_' })
        }
        elseif ($line -match '^\s*set\s+\$forward_scheme\s+"?([^";]+)"?;') { $current.scheme = $Matches[1] }
        elseif ($line -match '^\s*set\s+\$server\s+"?([^";]+)"?;') { $current.upstream = $Matches[1] }
        elseif ($line -match '^\s*set\s+\$port\s+"?([^";]+)"?;') { $current.port = $Matches[1] }
    }
    if ($current) { $proxyHosts.Add([pscustomobject]$current) }

    $certificates = @()
    try {
        $certRaw = Invoke-KeySsh -HostName $uri.Host -Port $uri.Port -UserName ([string]$service.ssh_user) `
            -Command "sudo -n find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -printf '%f\n'"
        $certificates = @($certRaw -split "`n" | Where-Object { $_ } | Sort-Object)
    } catch { }

    [pscustomobject]@{
        hostname = $hostName
        kernel = $kernel
        containers = @($containers)
        running_services = @($runningServices)
        proxy_hosts = @($proxyHosts | ForEach-Object { $_ })
        certificate_names = @($certificates)
    }
}

function Get-UniFiSnapshot {
    $service = $inventory.services.unifi
    $profile = Get-AccessProfile 'unifi-api-admin'
    $token = Get-VaultClipboardValue ([string]$profile.credential_ref)
    $base = ([string]$service.base_url).TrimEnd('/') + '/proxy/network/integration/v1'
    try {
        $get = {
            param([string]$Path)
            Invoke-JsonGet -Uri ($base + $Path) -HeaderName 'X-API-Key' -HeaderValue $token `
                -CertificateSha256 ([string]$service.certificate_sha256)
        }
        $info = & $get '/info'
        $sitesResponse = & $get '/sites'
        $sites = @(Get-ApiRows $sitesResponse)
        $siteSnapshots = @($sites | ForEach-Object {
            $site = $_
            $siteId = [string](Get-FirstPropertyValue $site @('id', 'siteId', '_id'))
            $devices = @()
            $clients = @()
            $networks = @()
            foreach ($target in @(
                @{ Name = 'devices'; Path = "/sites/$siteId/devices?offset=0&limit=200" },
                @{ Name = 'clients'; Path = "/sites/$siteId/clients?offset=0&limit=500" },
                @{ Name = 'networks'; Path = "/sites/$siteId/networks?offset=0&limit=200" }
            )) {
                try {
                    $rows = @(Get-ApiRows (& $get $target.Path))
                    if ($target.Name -eq 'devices') {
                        $devices = @($rows | ForEach-Object {
                            [pscustomobject]@{
                                id = [string](Get-FirstPropertyValue $_ @('id', 'deviceId', '_id'))
                                name = [string](Get-FirstPropertyValue $_ @('name', 'displayName', 'hostname'))
                                model = [string](Get-FirstPropertyValue $_ @('model', 'modelKey', 'shortname'))
                                type = [string](Get-FirstPropertyValue $_ @('type', 'deviceType', 'category'))
                                mac = [string](Get-FirstPropertyValue $_ @('macAddress', 'mac'))
                                ip = [string](Get-FirstPropertyValue $_ @('ipAddress', 'ip'))
                                firmware = [string](Get-FirstPropertyValue $_ @('firmwareVersion', 'version'))
                                state = [string](Get-FirstPropertyValue $_ @('state', 'status'))
                            }
                        })
                    }
                    elseif ($target.Name -eq 'clients') {
                        $clients = @($rows | ForEach-Object {
                            [pscustomobject]@{
                                id = [string](Get-FirstPropertyValue $_ @('id', 'clientId', '_id'))
                                name = [string](Get-FirstPropertyValue $_ @('name', 'displayName', 'hostname'))
                                mac = [string](Get-FirstPropertyValue $_ @('macAddress', 'mac'))
                                ip = [string](Get-FirstPropertyValue $_ @('ipAddress', 'ip'))
                                type = [string](Get-FirstPropertyValue $_ @('type', 'clientType'))
                                network_id = [string](Get-FirstPropertyValue $_ @('networkId', 'network'))
                                connected_device_id = [string](Get-FirstPropertyValue $_ @('connectedDeviceId', 'uplinkDeviceId'))
                            }
                        })
                    }
                    else {
                        $networks = @($rows | ForEach-Object {
                            [pscustomobject]@{
                                id = [string](Get-FirstPropertyValue $_ @('id', 'networkId', '_id'))
                                name = [string](Get-FirstPropertyValue $_ @('name', 'displayName'))
                                vlan_id = Get-FirstPropertyValue $_ @('vlanId', 'vlan')
                                subnet = [string](Get-FirstPropertyValue $_ @('subnet', 'gatewayIp', 'ipSubnet'))
                                management = [string](Get-FirstPropertyValue $_ @('management'))
                                enabled = Get-FirstPropertyValue $_ @('enabled')
                            }
                        })
                    }
                } catch { }
            }
            [pscustomobject]@{
                id = $siteId
                name = [string](Get-FirstPropertyValue $site @('name', 'displayName', 'description'))
                devices = @($devices)
                networks = @($networks)
                clients = @($clients)
            }
        })

        [pscustomobject]@{
            info = [pscustomobject]@{
                application_version = [string](Get-FirstPropertyValue $info @('applicationVersion', 'version'))
                controller_name = [string](Get-FirstPropertyValue $info @('controllerName', 'name'))
                host_id = [string](Get-FirstPropertyValue $info @('hostId', 'host_id'))
            }
            sites = @($siteSnapshots)
        }
    }
    finally {
        $token = $null
        Set-Clipboard -Value ''
    }
}

function Get-AdminSnapshot {
    $report = & (Join-Path $PSScriptRoot 'Get-AdminWorkstationReport.ps1')
    [pscustomobject]@{
        computer_name = [string]$report.computer_name
        windows = [string]$report.windows
        windows_version = [string]$report.windows_version
        windows_build = [string]$report.windows_build
        ram_gb = $report.ram_gb
        logical_processors = $report.logical_processors
        network = @($report.network)
        chrome = [string]$report.chrome
        wsl_installed = [bool]$report.wsl_installed
        tools = @($report.tools | ForEach-Object {
            [pscustomobject]@{ name = [string]$_.name; available = [bool]$_.available }
        })
    }
}

$status = [ordered]@{}
$snapshot = [ordered]@{
    schema_version = 1
    generated_at = [DateTimeOffset]::Now.ToString('o')
    source_status = $status
}
foreach ($source in @(
    @{ Name = 'proxmox'; Action = { Get-ProxmoxSnapshot } },
    @{ Name = 'home_assistant'; Action = { Get-HomeAssistantSnapshot } },
    @{ Name = 'reverse_proxy'; Action = { Get-ReverseProxySnapshot } },
    @{ Name = 'unifi'; Action = { Get-UniFiSnapshot } },
    @{ Name = 'admin_workstation'; Action = { Get-AdminSnapshot } },
    @{ Name = 'lan_services'; Action = { @(& (Join-Path $PSScriptRoot 'Find-HomelabServices.ps1')) } }
)) {
    try {
        $snapshot[$source.Name] = & $source.Action
        $status[$source.Name] = 'ok'
    }
    catch {
        $snapshot[$source.Name] = $null
        $status[$source.Name] = "failed: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
    }
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$runtimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot '.runtime'))
if (-not $resolvedOutput.StartsWith($runtimeRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Snapshot output must stay below the repository .runtime directory.'
}
$outputDirectory = Split-Path -Parent $resolvedOutput
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$snapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
Set-Clipboard -Value ''

[pscustomobject]@{
    success = -not (@($status.Values | Where-Object { $_ -ne 'ok' }).Count)
    generated_at = $snapshot.generated_at
    output_path = $resolvedOutput
    source_status = $status
}
