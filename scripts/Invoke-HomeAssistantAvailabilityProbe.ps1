[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 10,

    [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab\availability'),

    [switch]$PassThru,

    [switch]$IncludePathDiagnostics,

    [switch]$LibraryOnly,

    [string]$CurlExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Fixed, secret-free targets verified in the structured Homelab inventory.
$externalUri = [uri]'https://home-automation.example.invalid/'
$internalUri = [uri]'http://192.0.2.20:8123/'

function New-CurlProbeErrorResult {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Reason,
        [long]$LatencyMilliseconds = 0
    )

    [pscustomobject]@{
        url = $Uri.AbsoluteUri
        probe_engine = 'curl'
        probe_valid = $false
        probe_error = $Reason
        reachable = $false
        online = $false
        status_code = $null
        latency_ms = [Math]::Max(0, $LatencyMilliseconds)
        outcome = 'probe_error'
        tls_state = if ($Uri.Scheme -eq 'https') { 'unknown' } else { 'not_applicable' }
    }
}

function Start-CurlEndpointProbe {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][int]$Timeout
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $ExecutablePath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
            '--silent',
            '--show-error',
            '--location',
            '--max-redirs', '3',
            '--connect-timeout', [string]$Timeout,
            '--max-time', [string]$Timeout,
            '--output', 'NUL',
            '--write-out', '%{http_code}|%{time_total}|%{ssl_verify_result}',
            '--user-agent', 'CodexAdmin-HomeAssistantAvailability/2.0',
            $Uri.AbsoluteUri
        )) {
            $startInfo.ArgumentList.Add([string]$argument)
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'curl process did not start.' }
        [pscustomobject]@{
            uri = $Uri
            process = $process
            stopwatch = $stopwatch
            stdout_task = $process.StandardOutput.ReadToEndAsync()
            stderr_task = $process.StandardError.ReadToEndAsync()
            timeout = $Timeout
            start_error = $null
        }
    }
    catch {
        $stopwatch.Stop()
        if ($process) { $process.Dispose() }
        [pscustomobject]@{
            uri = $Uri
            process = $null
            stopwatch = $stopwatch
            stdout_task = $null
            stderr_task = $null
            timeout = $Timeout
            start_error = 'curl_start_failed'
        }
    }
}

function ConvertFrom-CurlProbeOutput {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Output,
        [long]$FallbackLatencyMilliseconds = 0,
        [switch]$WatchdogTimeout
    )

    if ($WatchdogTimeout) {
        return New-CurlProbeErrorResult -Uri $Uri -Reason 'curl_watchdog_timeout' `
            -LatencyMilliseconds $FallbackLatencyMilliseconds
    }

    $pathOutcomes = @{
        6 = 'dns_error'
        7 = 'connectivity_error'
        28 = 'timeout'
        35 = 'tls_handshake_failed'
        60 = 'tls_validation_failed'
    }
    if ($ExitCode -ne 0) {
        if (-not $pathOutcomes.ContainsKey($ExitCode)) {
            return New-CurlProbeErrorResult -Uri $Uri -Reason ("curl_exit_{0}" -f $ExitCode) `
                -LatencyMilliseconds $FallbackLatencyMilliseconds
        }

        [pscustomobject]@{
            url = $Uri.AbsoluteUri
            probe_engine = 'curl'
            probe_valid = $true
            probe_error = $null
            reachable = $false
            online = $false
            status_code = $null
            latency_ms = [Math]::Max(0, $FallbackLatencyMilliseconds)
            outcome = [string]$pathOutcomes[$ExitCode]
            tls_state = if ($Uri.Scheme -ne 'https') {
                'not_applicable'
            }
            elseif ($ExitCode -in @(35, 60)) {
                'failed'
            }
            else {
                'unknown'
            }
        }
        return
    }

    $parts = @(([string]$Output).Trim() -split '\|', 3)
    $statusCode = 0
    $elapsedSeconds = 0.0
    $sslVerifyResult = 0
    $validOutput = $parts.Count -eq 3 -and
        [int]::TryParse($parts[0], [ref]$statusCode) -and
        [double]::TryParse(
            $parts[1],
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$elapsedSeconds
        ) -and
        [int]::TryParse($parts[2], [ref]$sslVerifyResult) -and
        $statusCode -ge 100 -and $statusCode -le 599 -and
        $elapsedSeconds -ge 0
    if (-not $validOutput) {
        return New-CurlProbeErrorResult -Uri $Uri -Reason 'curl_output_invalid' `
            -LatencyMilliseconds $FallbackLatencyMilliseconds
    }

    $online = $statusCode -ge 200 -and $statusCode -lt 400
    $outcome = if ($online) {
        'ok'
    }
    elseif ($statusCode -ge 400 -and $statusCode -lt 500) {
        'http_client_error'
    }
    elseif ($statusCode -ge 500) {
        'http_server_error'
    }
    else {
        'unexpected_http_status'
    }
    [pscustomobject]@{
        url = $Uri.AbsoluteUri
        probe_engine = 'curl'
        probe_valid = $true
        probe_error = $null
        reachable = $true
        online = $online
        status_code = $statusCode
        latency_ms = [Math]::Max(0, [long][Math]::Round($elapsedSeconds * 1000))
        outcome = $outcome
        tls_state = if ($Uri.Scheme -eq 'https' -and $sslVerifyResult -eq 0) {
            'validated'
        }
        elseif ($Uri.Scheme -eq 'https') {
            'failed'
        }
        else {
            'not_applicable'
        }
    }
}

function Complete-CurlEndpointProbe {
    param([Parameter(Mandatory)][object]$Probe)

    if ($Probe.start_error) {
        return New-CurlProbeErrorResult -Uri $Probe.uri -Reason ([string]$Probe.start_error) `
            -LatencyMilliseconds ([long]$Probe.stopwatch.ElapsedMilliseconds)
    }

    $watchdogTimeout = $false
    try {
        if (-not $Probe.process.WaitForExit(([int]$Probe.timeout + 5) * 1000)) {
            $watchdogTimeout = $true
            $Probe.process.Kill($true)
            $Probe.process.WaitForExit()
        }
        if ($Probe.stopwatch.IsRunning) { $Probe.stopwatch.Stop() }
        $stdout = [string]$Probe.stdout_task.GetAwaiter().GetResult()
        [void]$Probe.stderr_task.GetAwaiter().GetResult()
        ConvertFrom-CurlProbeOutput -Uri $Probe.uri -ExitCode ([int]$Probe.process.ExitCode) `
            -Output $stdout -FallbackLatencyMilliseconds ([long]$Probe.stopwatch.ElapsedMilliseconds) `
            -WatchdogTimeout:$watchdogTimeout
    }
    catch {
        if ($Probe.stopwatch.IsRunning) { $Probe.stopwatch.Stop() }
        New-CurlProbeErrorResult -Uri $Probe.uri -Reason 'curl_completion_failed' `
            -LatencyMilliseconds ([long]$Probe.stopwatch.ElapsedMilliseconds)
    }
    finally {
        $Probe.process.Dispose()
    }
}

function Get-ExternalPathDiagnostics {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$LocalProxyAddress,
        [Parameter(Mandatory)][int]$Timeout
    )

    $dnsStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $addresses = @()
    $dnsOutcome = 'resolution_error'
    try {
        $dnsTask = [Net.Dns]::GetHostAddressesAsync($Uri.DnsSafeHost)
        $dnsWinner = [Threading.Tasks.Task]::WhenAny(
            $dnsTask,
            [Threading.Tasks.Task]::Delay([TimeSpan]::FromSeconds($Timeout))
        ).GetAwaiter().GetResult()
        if (-not [object]::ReferenceEquals($dnsWinner, $dnsTask)) {
            $dnsOutcome = 'timeout'
        }
        else {
            $addresses = @($dnsTask.GetAwaiter().GetResult())
            $dnsOutcome = if ($addresses.Count -gt 0) { 'ok' } else { 'no_addresses' }
        }
    }
    catch {
        $dnsOutcome = 'resolution_error'
    }
    finally {
        $dnsStopwatch.Stop()
    }

    $publicTcpStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $publicTcpOutcome = if ($addresses.Count -gt 0) { 'connectivity_error' } else { 'not_attempted' }
    $publicTcpAttempts = 0
    try {
        foreach ($address in $addresses) {
            $publicTcpAttempts++
            $tcpClient = [Net.Sockets.TcpClient]::new($address.AddressFamily)
            try {
                $connectTask = $tcpClient.ConnectAsync($address, $Uri.Port)
                $connectWinner = [Threading.Tasks.Task]::WhenAny(
                    $connectTask,
                    [Threading.Tasks.Task]::Delay([TimeSpan]::FromSeconds($Timeout))
                ).GetAwaiter().GetResult()
                if (-not [object]::ReferenceEquals($connectWinner, $connectTask)) {
                    $publicTcpOutcome = 'timeout'
                    continue
                }
                [void]$connectTask.GetAwaiter().GetResult()
                $publicTcpOutcome = 'ok'
                break
            }
            catch {
                $publicTcpOutcome = 'connectivity_error'
            }
            finally {
                $tcpClient.Dispose()
            }
        }
    }
    finally {
        $publicTcpStopwatch.Stop()
    }

    $localProxyStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $localProxyOutcome = 'transport_error'
    $localProxyStatusCode = $null
    $localProxyTlsState = 'unknown'
    $localTcpClient = $null
    $sslStream = $null
    $reader = $null
    $authenticationCancellation = $null
    try {
        $localTcpClient = [Net.Sockets.TcpClient]::new()
        $localConnectTask = $localTcpClient.ConnectAsync($LocalProxyAddress, $Uri.Port)
        $localConnectWinner = [Threading.Tasks.Task]::WhenAny(
            $localConnectTask,
            [Threading.Tasks.Task]::Delay([TimeSpan]::FromSeconds($Timeout))
        ).GetAwaiter().GetResult()
        if (-not [object]::ReferenceEquals($localConnectWinner, $localConnectTask)) {
            throw [TimeoutException]::new('Local proxy connection timed out.')
        }
        [void]$localConnectTask.GetAwaiter().GetResult()

        $sslStream = [Net.Security.SslStream]::new($localTcpClient.GetStream(), $false)
        $authenticationCancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($Timeout))
        $authenticationOptions = [Net.Security.SslClientAuthenticationOptions]::new()
        $authenticationOptions.TargetHost = $Uri.DnsSafeHost
        [void]$sslStream.AuthenticateAsClientAsync(
            $authenticationOptions,
            $authenticationCancellation.Token
        ).GetAwaiter().GetResult()
        $localProxyTlsState = 'validated'
        $sslStream.ReadTimeout = $Timeout * 1000
        $sslStream.WriteTimeout = $Timeout * 1000

        $requestBytes = [Text.Encoding]::ASCII.GetBytes(
            "GET / HTTP/1.1`r`nHost: $($Uri.DnsSafeHost)`r`nUser-Agent: CodexAdmin-HomeAssistantPathDiagnostic/1.0`r`nConnection: close`r`n`r`n"
        )
        $sslStream.Write($requestBytes, 0, $requestBytes.Length)
        $sslStream.Flush()
        $reader = [IO.StreamReader]::new($sslStream, [Text.Encoding]::ASCII, $false, 1024, $true)
        $statusLine = $reader.ReadLine()
        if ($statusLine -match '^HTTP/\S+\s+(\d{3})\b') {
            $localProxyStatusCode = [int]$Matches[1]
            $localProxyOutcome = if ($localProxyStatusCode -ge 200 -and $localProxyStatusCode -lt 400) {
                'ok'
            }
            elseif ($localProxyStatusCode -ge 400 -and $localProxyStatusCode -lt 500) {
                'http_client_error'
            }
            elseif ($localProxyStatusCode -ge 500 -and $localProxyStatusCode -lt 600) {
                'http_server_error'
            }
            else {
                'unexpected_http_status'
            }
        }
        else {
            $localProxyOutcome = 'invalid_http_response'
        }
    }
    catch {
        $cursor = $_.Exception
        $hasTlsError = $false
        $hasSocketError = $false
        $hasTimeout = $false
        while ($cursor) {
            if ($cursor -is [Security.Authentication.AuthenticationException]) { $hasTlsError = $true }
            if ($cursor -is [Net.Sockets.SocketException]) { $hasSocketError = $true }
            if ($cursor -is [TimeoutException] -or $cursor -is [OperationCanceledException]) { $hasTimeout = $true }
            $cursor = $cursor.InnerException
        }
        $localProxyOutcome = if ($hasTimeout) {
            'timeout'
        }
        elseif ($hasTlsError) {
            $localProxyTlsState = 'failed'
            'tls_validation_failed'
        }
        elseif ($hasSocketError) {
            'connectivity_error'
        }
        else {
            'transport_error'
        }
    }
    finally {
        $localProxyStopwatch.Stop()
        if ($reader) { $reader.Dispose() }
        if ($sslStream) { $sslStream.Dispose() }
        if ($authenticationCancellation) { $authenticationCancellation.Dispose() }
        if ($localTcpClient) { $localTcpClient.Dispose() }
    }

    [pscustomobject]@{
        trigger = if ($IncludePathDiagnostics) { 'requested' } else { 'external_failure' }
        dns = [pscustomobject]@{
            outcome = $dnsOutcome
            address_count = $addresses.Count
            latency_ms = [Math]::Max(0, [long]$dnsStopwatch.ElapsedMilliseconds)
        }
        public_tcp = [pscustomobject]@{
            outcome = $publicTcpOutcome
            attempts = $publicTcpAttempts
            latency_ms = [Math]::Max(0, [long]$publicTcpStopwatch.ElapsedMilliseconds)
        }
        local_reverse_proxy = [pscustomobject]@{
            outcome = $localProxyOutcome
            status_code = $localProxyStatusCode
            latency_ms = [Math]::Max(0, [long]$localProxyStopwatch.ElapsedMilliseconds)
            tls_state = $localProxyTlsState
        }
        note = 'Immediate secret-free follow-up; no addresses, headers, bodies, cookies, or exception text retained.'
    }
}

if ($LibraryOnly) { return }

$resolvedCurl = $null
if ($CurlExecutable) {
    $candidate = [IO.Path]::GetFullPath($CurlExecutable)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $resolvedCurl = $candidate }
}
else {
    $curlCommand = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($curlCommand) { $resolvedCurl = [IO.Path]::GetFullPath($curlCommand.Source) }
}

if ($resolvedCurl) {
    # Start both processes before waiting so the internal endpoint remains a time-aligned reference.
    $externalProbe = Start-CurlEndpointProbe -Uri $externalUri -ExecutablePath $resolvedCurl -Timeout $TimeoutSeconds
    $internalProbe = Start-CurlEndpointProbe -Uri $internalUri -ExecutablePath $resolvedCurl -Timeout $TimeoutSeconds
    $external = Complete-CurlEndpointProbe -Probe $externalProbe
    $internal = Complete-CurlEndpointProbe -Probe $internalProbe
}
else {
    $external = New-CurlProbeErrorResult -Uri $externalUri -Reason 'curl_unavailable'
    $internal = New-CurlProbeErrorResult -Uri $internalUri -Reason 'curl_unavailable'
}

$correlation = if (-not $external.probe_valid -or -not $internal.probe_valid) {
    'probe_error'
}
elseif ($external.online -and $internal.online) {
    'both_online'
}
elseif (-not $external.online -and $internal.online) {
    'external_path_failure'
}
elseif (-not $external.online -and -not $internal.online) {
    'both_unavailable'
}
else {
    'internal_reference_failure'
}

$pathDiagnostics = $null
if ($IncludePathDiagnostics -or ([bool]$external.probe_valid -and -not $external.online)) {
    $pathDiagnostics = Get-ExternalPathDiagnostics `
        -Uri $externalUri `
        -LocalProxyAddress '192.0.2.30' `
        -Timeout ([Math]::Min($TimeoutSeconds, 5))
}

$record = [pscustomobject]@{
    schema_version = 2
    observed_at = [DateTimeOffset]::UtcNow.ToString('o')
    system_id = 'home_assistant'
    probe_engine = 'curl'
    correlation = $correlation
    external = $external
    internal = $internal
    path_diagnostics = $pathDiagnostics
}

$absoluteLogDirectory = [IO.Path]::GetFullPath($LogDirectory)
New-Item -ItemType Directory -Force -Path $absoluteLogDirectory | Out-Null
$logPath = Join-Path $absoluteLogDirectory ('home-assistant-availability-{0}.jsonl' -f (Get-Date).ToString('yyyy-MM-dd'))
$jsonLine = ($record | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($jsonLine)
$stream = [IO.FileStream]::new($logPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
}
finally {
    $stream.Dispose()
}

if ($PassThru) { $record }
