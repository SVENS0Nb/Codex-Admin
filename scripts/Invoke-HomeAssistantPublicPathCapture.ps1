[CmdletBinding()]
param(
    [ValidateRange(5, 240)]
    [int]$DurationMinutes = 90,

    [ValidateRange(10, 300)]
    [int]$IntervalSeconds = 20
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$diagnosticRoot = Join-Path $env:LOCALAPPDATA "CodexAdmin\homelab\diagnostics\ha-public-path-$runId"
New-Item -ItemType Directory -Path $diagnosticRoot -Force | Out-Null

$samplesPath = Join-Path $diagnosticRoot 'samples.jsonl'
$summaryPath = Join-Path $diagnosticRoot 'summary.json'
$vpsCapturePath = Join-Path $diagnosticRoot 'vps-tcp443-metadata.log'
$udmCapturePath = Join-Path $diagnosticRoot 'udm-tcp443-metadata.log'
$vpsErrorPath = Join-Path $diagnosticRoot 'vps-capture-error.log'
$udmErrorPath = Join-Path $diagnosticRoot 'udm-capture-error.log'

$remoteBase = "/tmp/codex-ha-path-$runId"
$captureSeconds = ($DurationMinutes * 60) + 120
$packetLimit = 20000
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
    & ssh.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "SSH command failed for $Target with exit code $LASTEXITCODE."
    }
}

function Start-RemoteCapture {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$PrivilegePrefix,
        [Parameter(Mandatory)] [string]$Filter,
        [string]$IdentityFile
    )

    $log = "$remoteBase.log"
    $remotePidPath = "$remoteBase.pid"
    $inner = "rm -f `"$log`" `"$remotePidPath`"; nohup timeout ${captureSeconds}s tcpdump -n -tttt -l -i any -s 0 -c $packetLimit `"$Filter`" > `"$log`" 2>&1 < /dev/null & echo `$! > `"$remotePidPath`""
    $command = if ($PrivilegePrefix) { "$PrivilegePrefix sh -c '$inner'" } else { "sh -c '$inner'" }
    Invoke-SshText -Target $Target -Command $command -IdentityFile $IdentityFile | Out-Null
}

function Save-And-CleanupRemoteCapture {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [string]$Destination,
        [Parameter(Mandatory)] [string]$ErrorDestination,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$PrivilegePrefix,
        [string]$IdentityFile
    )

    $log = "$remoteBase.log"
    $remotePidPath = "$remoteBase.pid"
    $inner = "if test -f `"$remotePidPath`"; then kill `$(cat `"$remotePidPath`") 2>/dev/null || true; fi; sleep 1; test -f `"$log`" && cat `"$log`"; rm -f `"$log`" `"$remotePidPath`""
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
        '--write-out', '%{http_code}|%{time_connect}|%{time_starttransfer}',
        $Uri
    )
    if ($Resolve) {
        $arguments = @('--resolve', $Resolve) + $arguments
    }
    $output = & curl.exe @arguments 2>$null
    $exitCode = $LASTEXITCODE
    $parts = [string]$output -split '\|', 3
    [pscustomobject]@{
        exit_code = $exitCode
        http_status = if ($parts.Count -ge 1) { $parts[0] } else { '000' }
        connect_seconds = if ($parts.Count -ge 2) { $parts[1] } else { $null }
        start_transfer_seconds = if ($parts.Count -ge 3) { $parts[2] } else { $null }
        ok = ($exitCode -eq 0 -and $parts.Count -ge 1 -and $parts[0] -match '^[1234][0-9][0-9]$')
    }
}

$startedAt = [datetimeoffset]::Now
$endsAt = $startedAt.AddMinutes($DurationMinutes)
$sampleCount = 0
$publicFailureCount = 0
$captureStart = @{}

try {
    try {
        Start-RemoteCapture -Target 'public-relay-vps' -PrivilegePrefix 'sudo -n' -Filter $vpsTcpFilter
        $captureStart.vps = 'started'
    } catch {
        $captureStart.vps = 'failed'
        $_.Exception.Message | Set-Content -LiteralPath $vpsErrorPath -Encoding utf8
    }

    try {
        Start-RemoteCapture -Target 'root@192.0.2.1' -PrivilegePrefix '' -Filter $udmTcpFilter -IdentityFile $udmIdentity
        $captureStart.udm = 'started'
    } catch {
        $captureStart.udm = 'failed'
        $_.Exception.Message | Set-Content -LiteralPath $udmErrorPath -Encoding utf8
    }

    while ([datetimeoffset]::Now -lt $endsAt) {
        $timestamp = [datetimeoffset]::Now
        $public = Invoke-CurlProbe -Uri 'https://home-automation.example.invalid/'
        $sample = [ordered]@{
            observed_at = $timestamp.ToString('o')
            public = $public
        }

        if (-not $public.ok) {
            $publicFailureCount++
            $sample.internal_ha = Invoke-CurlProbe -Uri 'http://192.0.2.20:8123/'
            $sample.local_npm = Invoke-CurlProbe -Uri 'https://home-automation.example.invalid/' -Resolve 'home-automation.example.invalid:443:192.0.2.30'
            try {
                $dns = @(Resolve-DnsName -Name 'home-automation.example.invalid' -Type A -DnsOnly -ErrorAction Stop)
                $sample.dns = @{ ok = $true; address_count = @($dns | Where-Object Type -eq 'A').Count }
            } catch {
                $sample.dns = @{ ok = $false; address_count = 0 }
            }
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $connected = $tcp.ConnectAsync('home-automation.example.invalid', 443).Wait(3000) -and $tcp.Connected
                $tcp.Dispose()
                $sample.public_tcp_443 = @{ ok = $connected }
            } catch {
                $sample.public_tcp_443 = @{ ok = $false }
            }
        }

        $sample | ConvertTo-Json -Compress -Depth 6 | Add-Content -LiteralPath $samplesPath -Encoding utf8
        $sampleCount++
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    if ($captureStart.vps -eq 'started') {
        Save-And-CleanupRemoteCapture -Target 'public-relay-vps' -Destination $vpsCapturePath `
            -ErrorDestination $vpsErrorPath -PrivilegePrefix 'sudo -n'
    }
    if ($captureStart.udm -eq 'started') {
        Save-And-CleanupRemoteCapture -Target 'root@192.0.2.1' -Destination $udmCapturePath `
            -ErrorDestination $udmErrorPath -PrivilegePrefix '' -IdentityFile $udmIdentity
    }
}

$summary = [ordered]@{
    run_id = $runId
    started_at = $startedAt.ToString('o')
    finished_at = [datetimeoffset]::Now.ToString('o')
    duration_minutes = $DurationMinutes
    interval_seconds = $IntervalSeconds
    samples = $sampleCount
    public_failures = $publicFailureCount
    remote_capture = $captureStart
    evidence_directory = $diagnosticRoot
    content_capture = $false
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding utf8
$summary | ConvertTo-Json -Compress -Depth 5
