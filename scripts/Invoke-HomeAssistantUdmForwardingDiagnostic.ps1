[CmdletBinding()]
param(
    [ValidateRange(15, 720)]
    [int]$DurationMinutes = 240,

    [ValidateRange(5, 120)]
    [int]$IntervalSeconds = 10,

    [ValidateRange(2, 60)]
    [int]$ContinueAfterClusterMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$diagnosticRoot = Join-Path $env:LOCALAPPDATA "CodexAdmin\homelab\diagnostics\ha-udm-forwarding-$runId"
New-Item -ItemType Directory -Path $diagnosticRoot -Force | Out-Null

$samplesPath = Join-Path $diagnosticRoot 'samples.jsonl'
$summaryPath = Join-Path $diagnosticRoot 'summary.json'
$vpsCapturePath = Join-Path $diagnosticRoot 'vps-tcp443-metadata.log'
$udmCapturePath = Join-Path $diagnosticRoot 'udm-tcp443-metadata.log'
$udmConntrackPath = Join-Path $diagnosticRoot 'udm-conntrack-events.log'
$udmSamplerPath = Join-Path $diagnosticRoot 'udm-forwarding-counters.log'
$udmThreatPath = Join-Path $diagnosticRoot 'udm-ids-events.jsonl'
$udmKernelPath = Join-Path $diagnosticRoot 'udm-kernel-network-events.log'
$vpsErrorPath = Join-Path $diagnosticRoot 'vps-capture-error.log'
$udmCaptureErrorPath = Join-Path $diagnosticRoot 'udm-capture-error.log'
$udmConntrackErrorPath = Join-Path $diagnosticRoot 'udm-conntrack-error.log'
$udmSamplerErrorPath = Join-Path $diagnosticRoot 'udm-sampler-error.log'
$udmCollectionErrorPath = Join-Path $diagnosticRoot 'udm-log-collection-error.log'

$remoteBase = "/tmp/codex-ha-udm-$runId"
$captureSeconds = ($DurationMinutes * 60) + 180
$packetLimit = 200000
$vpsTcpFilter = '((dst port 443 and (dst host 203.0.113.10 or dst host 198.51.100.20)) or (src port 443 and (src host 203.0.113.10 or src host 198.51.100.20))) and (tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0)'
$udmTcpFilter = '((dst port 443 and (dst host 198.51.100.20 or dst host 192.0.2.30)) or (src port 443 and (src host 198.51.100.20 or src host 192.0.2.30))) and (tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0)'
$udmIdentity = Join-Path $env:USERPROFILE '.ssh\codex_admin_ed25519'

function Invoke-SshText {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [string]$Command,
        [string]$IdentityFile
    )

    $arguments = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes')
    if ($IdentityFile) { $arguments += @('-i', $IdentityFile) }
    $arguments += @($Target, $Command)
    $result = & ssh.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed for $Target with exit code $LASTEXITCODE."
    }
    $result
}

function Start-RemoteCapture {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$PrivilegePrefix,
        [Parameter(Mandatory)] [string]$Filter,
        [Parameter(Mandatory)] [string]$Suffix,
        [string]$IdentityFile
    )

    $log = "$remoteBase-$Suffix.log"
    $pidPath = "$remoteBase-$Suffix.pid"
    $inner = "rm -f `"$log`" `"$pidPath`"; nohup timeout ${captureSeconds}s tcpdump -nn -tttt -l -i any -s 96 -c $packetLimit `"$Filter`" > `"$log`" 2>&1 < /dev/null & echo `$! > `"$pidPath`""
    $command = if ($PrivilegePrefix) { "$PrivilegePrefix sh -c '$inner'" } else { "sh -c '$inner'" }
    Invoke-SshText -Target $Target -Command $command -IdentityFile $IdentityFile | Out-Null
}

function Start-UdmRemoteScript {
    param(
        [Parameter(Mandatory)] [string]$Suffix,
        [Parameter(Mandatory)] [string]$Script
    )

    $scriptPath = "$remoteBase-$Suffix.sh"
    $logPath = "$remoteBase-$Suffix.log"
    $pidPath = "$remoteBase-$Suffix.pid"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    $command = "printf '%s' '$encoded' | base64 -d > '$scriptPath'; chmod 700 '$scriptPath'; rm -f '$logPath' '$pidPath'; nohup timeout ${captureSeconds}s sh '$scriptPath' > '$logPath' 2>&1 < /dev/null & echo `$! > '$pidPath'"
    Invoke-SshText -Target 'root@192.0.2.1' -Command $command -IdentityFile $udmIdentity | Out-Null
}

function Save-AndCleanupRemoteLog {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [string]$Suffix,
        [Parameter(Mandatory)] [string]$Destination,
        [Parameter(Mandatory)] [string]$ErrorDestination,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$PrivilegePrefix,
        [string]$IdentityFile
    )

    $logPath = "$remoteBase-$Suffix.log"
    $pidPath = "$remoteBase-$Suffix.pid"
    $scriptPath = "$remoteBase-$Suffix.sh"
    $inner = "if test -f `"$pidPath`"; then kill `$(cat `"$pidPath`") 2>/dev/null || true; fi; sleep 1; test -f `"$logPath`" && cat `"$logPath`"; rm -f `"$logPath`" `"$pidPath`" `"$scriptPath`""
    $command = if ($PrivilegePrefix) { "$PrivilegePrefix sh -c '$inner'" } else { "sh -c '$inner'" }
    $arguments = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes')
    if ($IdentityFile) { $arguments += @('-i', $IdentityFile) }
    $arguments += @($Target, $Command)
    & ssh.exe @arguments 2> $ErrorDestination | Set-Content -LiteralPath $Destination -Encoding utf8
}

function Invoke-CurlProbe {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [string]$Resolve
    )

    $arguments = @(
        '--silent', '--show-error', '--output', 'NUL',
        '--connect-timeout', '5', '--max-time', '10',
        '--write-out', '%{http_code}|%{time_connect}|%{time_starttransfer}|%{local_port}',
        $Uri
    )
    if ($Resolve) { $arguments = @('--resolve', $Resolve) + $arguments }
    $output = & curl.exe @arguments 2>$null
    $exitCode = $LASTEXITCODE
    $parts = [string]$output -split '\|', 4
    [pscustomobject]@{
        exit_code = $exitCode
        http_status = if ($parts.Count -ge 1) { $parts[0] } else { '000' }
        connect_seconds = if ($parts.Count -ge 2) { $parts[1] } else { $null }
        start_transfer_seconds = if ($parts.Count -ge 3) { $parts[2] } else { $null }
        local_port = if ($parts.Count -ge 4 -and $parts[3] -match '^\d+$') { [int]$parts[3] } else { $null }
        ok = ($exitCode -eq 0 -and $parts.Count -ge 1 -and $parts[0] -match '^[1234][0-9][0-9]$')
    }
}

function Get-FailureDiagnostics {
    $result = [ordered]@{}
    $result.internal_ha = Invoke-CurlProbe -Uri 'http://192.0.2.20:8123/'
    $result.local_npm = Invoke-CurlProbe -Uri 'https://home-automation.example.invalid/' -Resolve 'home-automation.example.invalid:443:192.0.2.30'
    try {
        $dns = @(Resolve-DnsName -Name 'home-automation.example.invalid' -Type A -DnsOnly -ErrorAction Stop)
        $result.dns = @{ ok = $true; address_count = @($dns | Where-Object Type -eq 'A').Count }
    }
    catch {
        $result.dns = @{ ok = $false; address_count = 0 }
    }
    try {
        $tcp = [Net.Sockets.TcpClient]::new()
        $connected = $tcp.ConnectAsync('home-automation.example.invalid', 443).Wait(3000) -and $tcp.Connected
        $tcp.Dispose()
        $result.public_tcp_443 = @{ ok = $connected }
    }
    catch {
        $result.public_tcp_443 = @{ ok = $false }
    }
    $result
}

$conntrackScript = @'
exec conntrack -E -e NEW,DESTROY -p tcp -s 198.51.100.1 -d 198.51.100.20 --dport 443 -o timestamp,extended
'@

$samplerScript = @'
while :; do
  ts=$(date -Iseconds)
  count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo -1)
  maximum=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo -1)
  stats=$(conntrack -S 2>/dev/null | awk '
    BEGIN { found=invalid=insert_failed=drop=early_drop=error=search_restart=0 }
    {
      for (i=1; i<=NF; i++) {
        split($i,a,"=")
        if (a[1]=="found") found+=a[2]
        else if (a[1]=="invalid") invalid+=a[2]
        else if (a[1]=="insert_failed") insert_failed+=a[2]
        else if (a[1]=="drop") drop+=a[2]
        else if (a[1]=="early_drop") early_drop+=a[2]
        else if (a[1]=="error") error+=a[2]
        else if (a[1]=="search_restart") search_restart+=a[2]
      }
    }
    END { printf "%s|%s|%s|%s|%s|%s|%s",found,invalid,insert_failed,drop,early_drop,error,search_restart }')
  nat_pkts=$(iptables -t nat -L UBIOS_PREROUTING_USER_HOOK -v -n -x --line-numbers 2>/dev/null | awk '$1==5 {print $2; exit}')
  accept_pkts=$(iptables -t filter -L UBIOS_WAN_LAN_USER -v -n -x --line-numbers 2>/dev/null | awk '$1==4 {print $2; exit}')
  invalid_drop=$(iptables -t filter -L UBIOS_WAN_LAN_USER -v -n -x --line-numbers 2>/dev/null | awk '$1==8 {print $2; exit}')
  default_drop=$(iptables -t filter -L UBIOS_WAN_LAN_USER -v -n -x --line-numbers 2>/dev/null | awk '$1==10 {print $2; exit}')
  mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  ids_pid=$(pidof ubnt-idsips-daemon 2>/dev/null | awk '{print $1}')
  if test -n "$ids_pid"; then ids_rss=$(awk '/^VmRSS:/ {print $2}' /proc/$ids_pid/status 2>/dev/null); else ids_rss=-1; fi
  load=$(awk '{print $1}' /proc/loadavg)
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$ts" "$count" "$maximum" "$stats" "${nat_pkts:--1}" "${accept_pkts:--1}" "${invalid_drop:--1}" "${default_drop:--1}" "${mem_kb:--1}" "${ids_rss:--1}" "$load"
  sleep 2
done
'@

$startedAt = [DateTimeOffset]::Now
$endsAt = $startedAt.AddMinutes($DurationMinutes)
$startedEpoch = $startedAt.ToUnixTimeSeconds()
$captureState = [ordered]@{ vps_tcp = 'not_started'; udm_tcp = 'not_started'; udm_conntrack = 'not_started'; udm_sampler = 'not_started' }
$sampleCount = 0
$publicFailureCount = 0
$recentFailureTimes = [Collections.Generic.List[DateTimeOffset]]::new()
$clusterDetectedAt = $null
$lastFailureAt = $null

try {
    try {
        Start-RemoteCapture -Target 'public-relay-vps' -PrivilegePrefix 'sudo -n' -Filter $vpsTcpFilter -Suffix 'vps-tcp'
        $captureState.vps_tcp = 'started'
    }
    catch {
        $captureState.vps_tcp = 'failed'
        $_.Exception.Message | Set-Content -LiteralPath $vpsErrorPath -Encoding utf8
    }

    try {
        Start-RemoteCapture -Target 'root@192.0.2.1' -PrivilegePrefix '' -Filter $udmTcpFilter -Suffix 'udm-tcp' -IdentityFile $udmIdentity
        $captureState.udm_tcp = 'started'
    }
    catch {
        $captureState.udm_tcp = 'failed'
        $_.Exception.Message | Set-Content -LiteralPath $udmCaptureErrorPath -Encoding utf8
    }

    try {
        Start-UdmRemoteScript -Suffix 'conntrack' -Script $conntrackScript
        $captureState.udm_conntrack = 'started'
    }
    catch {
        $captureState.udm_conntrack = 'failed'
        $_.Exception.Message | Set-Content -LiteralPath $udmConntrackErrorPath -Encoding utf8
    }

    try {
        Start-UdmRemoteScript -Suffix 'sampler' -Script $samplerScript
        $captureState.udm_sampler = 'started'
    }
    catch {
        $captureState.udm_sampler = 'failed'
        $_.Exception.Message | Set-Content -LiteralPath $udmSamplerErrorPath -Encoding utf8
    }

    while ([DateTimeOffset]::Now -lt $endsAt) {
        $timestamp = [DateTimeOffset]::Now
        $public = Invoke-CurlProbe -Uri 'https://home-automation.example.invalid/'
        $sample = [ordered]@{ observed_at = $timestamp.ToString('o'); public = $public }

        if (-not $public.ok) {
            $publicFailureCount++
            $lastFailureAt = $timestamp
            $recentFailureTimes.Add($timestamp)
            while ($recentFailureTimes.Count -gt 0 -and $recentFailureTimes[0] -lt $timestamp.AddMinutes(-2)) {
                $recentFailureTimes.RemoveAt(0)
            }
            if (-not $clusterDetectedAt -and $recentFailureTimes.Count -ge 2) {
                $clusterDetectedAt = $timestamp
            }
            $details = Get-FailureDiagnostics
            foreach ($key in $details.Keys) { $sample[$key] = $details[$key] }
        }

        $sample | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $samplesPath -Encoding utf8
        $sampleCount++

        if ($clusterDetectedAt -and $lastFailureAt -and [DateTimeOffset]::Now -ge $lastFailureAt.AddMinutes($ContinueAfterClusterMinutes)) {
            break
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    if ($captureState.vps_tcp -eq 'started') {
        Save-AndCleanupRemoteLog -Target 'public-relay-vps' -Suffix 'vps-tcp' -Destination $vpsCapturePath -ErrorDestination $vpsErrorPath -PrivilegePrefix 'sudo -n'
    }
    if ($captureState.udm_tcp -eq 'started') {
        Save-AndCleanupRemoteLog -Target 'root@192.0.2.1' -Suffix 'udm-tcp' -Destination $udmCapturePath -ErrorDestination $udmCaptureErrorPath -PrivilegePrefix '' -IdentityFile $udmIdentity
    }
    if ($captureState.udm_conntrack -eq 'started') {
        Save-AndCleanupRemoteLog -Target 'root@192.0.2.1' -Suffix 'conntrack' -Destination $udmConntrackPath -ErrorDestination $udmConntrackErrorPath -PrivilegePrefix '' -IdentityFile $udmIdentity
    }
    if ($captureState.udm_sampler -eq 'started') {
        Save-AndCleanupRemoteLog -Target 'root@192.0.2.1' -Suffix 'sampler' -Destination $udmSamplerPath -ErrorDestination $udmSamplerErrorPath -PrivilegePrefix '' -IdentityFile $udmIdentity
    }

    try {
        $threatLines = @(Invoke-SshText -Target 'root@192.0.2.1' -IdentityFile $udmIdentity -Command "journalctl --since '@$startedEpoch' -t ubnt-idsips-daemon --no-pager -o cat 2>/dev/null || true")
        foreach ($line in $threatLines) {
            $match = [regex]::Match([string]$line, '\{.*\}$')
            if (-not $match.Success) { continue }
            try { $event = $match.Value | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if (-not $event.PSObject.Properties['alert'] -or -not $event.PSObject.Properties['dest_port']) { continue }
            $isRelevant = (($event.dest_ip -eq '192.0.2.30' -and [int]$event.dest_port -eq 443) -or ($event.src_ip -eq '198.51.100.1' -and [int]$event.dest_port -eq 443))
            if (-not $isRelevant) { continue }
            [ordered]@{
                timestamp = [string]$event.timestamp
                action = [string]$event.alert.action
                signature_id = [int]$event.alert.signature_id
                signature = [string]$event.alert.signature
                category = [string]$event.alert.category
                severity = [int]$event.alert.severity
                src_scope = if ($event.src_ip -eq '198.51.100.1') { 'wireguard_relay' } else { 'other' }
                src_port = [int]$event.src_port
                dest_scope = if ($event.dest_ip -eq '192.0.2.30') { 'reverse_proxy' } else { 'other' }
                dest_port = [int]$event.dest_port
                app_proto = [string]$event.app_proto
                flow_start = [string]$event.flow.start
            } | ConvertTo-Json -Compress -Depth 4 | Add-Content -LiteralPath $udmThreatPath -Encoding utf8
        }

        $kernelLines = @(Invoke-SshText -Target 'root@192.0.2.1' -IdentityFile $udmIdentity -Command "journalctl -k --since '@$startedEpoch' --no-pager -o short-iso 2>/dev/null | grep -Eai 'conntrack|nf_conntrack|table full|early.drop|insert.failed|netlink|suricata|ids|ips|oom|out of memory' || true")
        $kernelLines | Set-Content -LiteralPath $udmKernelPath -Encoding utf8
    }
    catch {
        $_.Exception.Message | Set-Content -LiteralPath $udmCollectionErrorPath -Encoding utf8
    }
}

$finishedAt = [DateTimeOffset]::Now
$summary = [ordered]@{
    schema_version = 1
    run_id = $runId
    started_at = $startedAt.ToString('o')
    finished_at = $finishedAt.ToString('o')
    requested_duration_minutes = $DurationMinutes
    actual_duration_seconds = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 1)
    interval_seconds = $IntervalSeconds
    continue_after_cluster_minutes = $ContinueAfterClusterMinutes
    samples = $sampleCount
    public_failures = $publicFailureCount
    failure_cluster_detected = [bool]$clusterDetectedAt
    cluster_detected_at = if ($clusterDetectedAt) { $clusterDetectedAt.ToString('o') } else { $null }
    remote_capture = $captureState
    evidence_directory = $diagnosticRoot
    content_capture = $false
    notes = 'Read-only diagnostic. Packet logs contain TCP connection metadata only; IDS records are reduced to selected classification and flow metadata.'
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding utf8
$summary | ConvertTo-Json -Compress -Depth 5
