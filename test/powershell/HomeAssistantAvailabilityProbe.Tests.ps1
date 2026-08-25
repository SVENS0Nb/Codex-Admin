$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repositoryRoot 'scripts\Invoke-HomeAssistantAvailabilityProbe.ps1') -LibraryOnly

function New-TestCurlProbeProcess {
    param(
        [Parameter(Mandatory)][int]$SleepMilliseconds,
        [int]$Timeout = 5
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $env:ComSpec
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $pingCount = [Math]::Max(2, [int][Math]::Ceiling($SleepMilliseconds / 1000.0) + 1)
    foreach ($argument in @('/d', '/s', '/c', "ping.exe -n $pingCount 127.0.0.1 >NUL & echo 200^|0.800^|0")) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) { throw 'Fixture process did not start.' }
    [pscustomobject]@{
        uri = [uri]'https://example.invalid/'
        process = $process
        stopwatch = $stopwatch
        stdout_task = $process.StandardOutput.ReadToEndAsync()
        stderr_task = $process.StandardError.ReadToEndAsync()
        timeout = $Timeout
        start_error = $null
    }
}

Describe 'Home Assistant curl availability probe result parsing' {
    It 'accepts a validated HTTP success result' {
        $result = ConvertFrom-CurlProbeOutput -Uri ([uri]'https://example.invalid/') `
            -ExitCode 0 -Output '200|0.125|0'
        $result.probe_valid | Should Be $true
        $result.online | Should Be $true
        $result.status_code | Should Be 200
        $result.latency_ms | Should Be 125
        $result.tls_state | Should Be 'validated'
    }

    It 'classifies certificate failures as valid path observations' {
        $result = ConvertFrom-CurlProbeOutput -Uri ([uri]'https://example.invalid/') `
            -ExitCode 60 -Output '' -FallbackLatencyMilliseconds 41
        $result.probe_valid | Should Be $true
        $result.online | Should Be $false
        $result.outcome | Should Be 'tls_validation_failed'
        $result.tls_state | Should Be 'failed'
    }

    It 'classifies curl timeouts as valid path observations' {
        $result = ConvertFrom-CurlProbeOutput -Uri ([uri]'http://192.0.2.1/') `
            -ExitCode 28 -Output '' -FallbackLatencyMilliseconds 1000
        $result.probe_valid | Should Be $true
        $result.outcome | Should Be 'timeout'
        $result.tls_state | Should Be 'not_applicable'
    }

    It 'rejects operational curl failures as probe errors' {
        $result = ConvertFrom-CurlProbeOutput -Uri ([uri]'https://example.invalid/') `
            -ExitCode 2 -Output '' -FallbackLatencyMilliseconds 3
        $result.probe_valid | Should Be $false
        $result.outcome | Should Be 'probe_error'
        $result.probe_error | Should Be 'curl_exit_2'
    }

    It 'rejects malformed curl write-out data' {
        $result = ConvertFrom-CurlProbeOutput -Uri ([uri]'https://example.invalid/') `
            -ExitCode 0 -Output 'not-a-result'
        $result.probe_valid | Should Be $false
        $result.probe_error | Should Be 'curl_output_invalid'
    }

    It 'completes two already-started probes concurrently and disposes both processes' {
        $first = New-TestCurlProbeProcess -SleepMilliseconds 1500
        $second = New-TestCurlProbeProcess -SleepMilliseconds 1500
        $firstId = $first.process.Id
        $secondId = $second.process.Id
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        $firstResult = Complete-CurlEndpointProbe -Probe $first
        $secondResult = Complete-CurlEndpointProbe -Probe $second
        $elapsed.Stop()

        $firstResult.probe_valid | Should Be $true
        $secondResult.probe_valid | Should Be $true
        $elapsed.ElapsedMilliseconds -lt 3000 | Should Be $true
        $null -eq (Get-Process -Id $firstId -ErrorAction SilentlyContinue) | Should Be $true
        $null -eq (Get-Process -Id $secondId -ErrorAction SilentlyContinue) | Should Be $true
    }

    It 'kills an overlong probe tree and reports a watchdog tool error' {
        $probe = New-TestCurlProbeProcess -SleepMilliseconds 10000 -Timeout (-4)
        $processId = $probe.process.Id
        $result = Complete-CurlEndpointProbe -Probe $probe

        $result.probe_valid | Should Be $false
        $result.probe_error | Should Be 'curl_watchdog_timeout'
        $null -eq (Get-Process -Id $processId -ErrorAction SilentlyContinue) | Should Be $true
    }
}
