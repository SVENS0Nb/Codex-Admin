$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("homelab-daily-review-tests-" + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA
$previousAnalyzerMode = $env:HOMELAB_FAKE_ANALYZER_MODE
$previousAnalyzerState = $env:HOMELAB_FAKE_ANALYZER_STATE
$previousAnalyzerJson = $env:HOMELAB_FAKE_ANALYZER_JSON
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$env:LOCALAPPDATA = $testRoot

. (Join-Path $repositoryRoot 'scripts\Invoke-HomelabDailyLogReview.ps1') -LibraryOnly -MaximumAnalysisAttempts 2

function Reset-DailyReviewTestState {
    $script:Events.Clear()
    $script:Coverage.Clear()
    $script:Stages.Clear()
    $script:AnalysisAttempts.Clear()
    $script:AnalysisStatus = 'pending'
    $script:AnalysisSkipReason = $null
}

Describe 'Homelab daily review core' {
    It 'redacts common credential material' {
        $safe = Protect-LogText 'password=forbidden Bearer abcdefghijklmnop'
        $safe | Should Not Match 'forbidden'
        $safe | Should Not Match 'abcdefghijklmnop'
    }

    It 'preserves empty arrays while sanitizing and renders zero counts without phantom entries' {
        Reset-DailyReviewTestState
        $analysis = Protect-Object ([pscustomobject]@{
            overall_status = 'ok'
            executive_summary = 'No relevant findings.'
            systems = @()
            findings = @()
            watch_items = @()
            notable_events = @()
            coverage_gaps = @()
        })

        $null -eq $analysis.findings | Should Be $false
        @($analysis.findings).Count | Should Be 0
        $null -eq $analysis.watch_items | Should Be $false
        @($analysis.watch_items).Count | Should Be 0
        $null -eq $analysis.coverage_gaps | Should Be $false
        @($analysis.coverage_gaps).Count | Should Be 0

        $markdown = Convert-AnalysisToMarkdown -Analysis $analysis
        $markdown | Should Match '0 nennenswerte Findings · 0 interne Beobachtungspunkte'
        $markdown | Should Not Match '## Abdeckungslücken'
    }

    It 'reclassifies the known legacy HttpClient transport pattern as a monitor coverage gap' {
        Reset-DailyReviewTestState
        New-Item -ItemType Directory -Path $availabilityRoot -Force | Out-Null
        Get-ChildItem -LiteralPath $availabilityRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force
        $fixture = [ordered]@{
            schema_version = 1
            observed_at = [DateTimeOffset]::Now.ToString('o')
            correlation = 'external_path_failure'
            external = [ordered]@{ online = $false; outcome = 'transport_error'; latency_ms = 10 }
            internal = [ordered]@{ online = $true; outcome = 'ok'; latency_ms = 5 }
            path_diagnostics = [ordered]@{
                dns = [ordered]@{ outcome = 'ok' }
                public_tcp = [ordered]@{ outcome = 'ok' }
                local_reverse_proxy = [ordered]@{ outcome = 'ok' }
            }
        }
        $fixturePath = Join-Path $availabilityRoot 'home-assistant-availability-legacy.jsonl'
        Set-Content -LiteralPath $fixturePath -Encoding utf8NoBOM -Value ($fixture | ConvertTo-Json -Depth 8 -Compress)

        Invoke-HomeAssistantAvailabilityCollection

        @($script:Coverage).Count | Should Be 1
        $script:Coverage[0].success | Should Be $false
        ($script:Events.message -join ' ') | Should Match 'Prüfwerkzeug'
        ($script:Events.message -join ' ') | Should Not Match 'Der externe Home-Assistant-Pfad war bei'
    }

    It 'fails closed for missing or malformed control-plane status artifacts' {
        $missing = Read-ControlPlaneStatusFile -Path (Join-Path $testRoot 'missing.json') `
            -Kind quality -MaximumAgeHours 24
        $missing.valid | Should Be $false
        $missing.error | Should Match 'fehlt'

        $malformedPath = Join-Path $testRoot 'malformed.json'
        Set-Content -LiteralPath $malformedPath -Encoding utf8NoBOM -Value '{broken'
        $malformed = Read-ControlPlaneStatusFile -Path $malformedPath -Kind quality -MaximumAgeHours 24
        $malformed.valid | Should Be $false
    }

    It 'distinguishes an operational quality failure from stale status coverage' {
        $reference = [DateTimeOffset]'2026-08-25T18:00:00+02:00'
        $failurePath = Join-Path $testRoot 'quality-failed.json'
        [ordered]@{
            schema_version = 1
            generated_at = $reference.AddHours(-1).ToString('o')
            success = $false
            failure_reason = 'fixture failure'
        } | ConvertTo-Json | Set-Content -LiteralPath $failurePath -Encoding utf8NoBOM
        $failure = Read-ControlPlaneStatusFile -Path $failurePath -Kind quality `
            -MaximumAgeHours 24 -ReferenceTime $reference
        $failure.valid | Should Be $true
        $failure.success | Should Be $false
        $failure.stale | Should Be $false
        $failureCoverage = Get-ControlPlaneStatusCoverageResult -Status $failure
        $failureCoverage.success | Should Be $false
        $failureCoverage.error | Should Match 'fixture failure'

        $stalePath = Join-Path $testRoot 'quality-stale.json'
        [ordered]@{
            schema_version = 1
            generated_at = $reference.AddHours(-25).ToString('o')
            success = $true
        } | ConvertTo-Json | Set-Content -LiteralPath $stalePath -Encoding utf8NoBOM
        $stale = Read-ControlPlaneStatusFile -Path $stalePath -Kind quality `
            -MaximumAgeHours 24 -ReferenceTime $reference
        $stale.valid | Should Be $true
        $stale.success | Should Be $true
        $stale.stale | Should Be $true
        (Get-ControlPlaneStatusCoverageResult -Status $stale).success | Should Be $false

        $wrongBooleanPath = Join-Path $testRoot 'quality-string-boolean.json'
        [ordered]@{
            schema_version = 1
            generated_at = $reference.ToString('o')
            success = 'false'
        } | ConvertTo-Json | Set-Content -LiteralPath $wrongBooleanPath -Encoding utf8NoBOM
        $wrongBoolean = Read-ControlPlaneStatusFile -Path $wrongBooleanPath -Kind quality `
            -MaximumAgeHours 24 -ReferenceTime $reference
        $wrongBoolean.valid | Should Be $false
        $wrongBoolean.error | Should Match 'booleschen'
    }

    It 'requires a successful isolated restore result in recovery status' {
        $recoveryPath = Join-Path $testRoot 'recovery.json'
        [ordered]@{
            schema_version = 1
            generated_at = [DateTimeOffset]::Now.ToString('o')
            success = $true
            restore_test_passed = $false
        } | ConvertTo-Json | Set-Content -LiteralPath $recoveryPath -Encoding utf8NoBOM
        $recovery = Read-ControlPlaneStatusFile -Path $recoveryPath -Kind recovery -MaximumAgeHours 840
        $recovery.valid | Should Be $true
        $recovery.success | Should Be $false
    }

    It 'marks managed Job Engine defects as unhealthy coverage' {
        $healthy = Test-ManagedJobEngineState -ExpectedNames @('quality', 'recovery') -Jobs @(
            [pscustomobject]@{ name = 'quality'; enabled = $true; preflight_status = 'passed'; last_status = 'succeeded' },
            [pscustomobject]@{ name = 'recovery'; enabled = $true; preflight_status = 'passed'; last_status = 'succeeded' }
        )
        $healthy.healthy | Should Be $true

        $failed = Test-ManagedJobEngineState -ExpectedNames @('quality', 'recovery') -Jobs @(
            [pscustomobject]@{ name = 'quality'; enabled = $true; preflight_status = 'passed'; last_status = 'failed' },
            [pscustomobject]@{ name = 'recovery'; enabled = $false; preflight_status = 'failed'; last_status = $null }
        )
        $failed.healthy | Should Be $false
        @($failed.messages).Count | Should Be 2
        ($failed.messages -join ' ') | Should Match 'letzter Lauf=failed'
        ($failed.messages -join ' ') | Should Match 'deaktiviert'
    }

    It 'never promotes uncorrelated raw events in fallback mode' {
        Reset-DailyReviewTestState
        Add-SourceLines -SystemId 'proxmox' -Source 'fixture' -Lines @('2026-08-25 12:00:00 CRITICAL simulated disk error')
        $analysis = New-FallbackAnalysis -Reason 'simulated analyzer outage'
        @($analysis.findings).Count | Should Be 0
        @($analysis.watch_items).Count | Should Be 0
        $analysis.overall_status | Should Be 'unknown'
        $script:AnalysisStatus | Should Be 'fallback_zero_findings'
    }

    It 'retries once against the same snapshot and accepts the second valid result' {
        Reset-DailyReviewTestState
        Add-SourceLines -SystemId 'proxmox' -Source 'fixture' -Lines @()
        $fake = Join-Path $repositoryRoot 'test\fixtures\Fake-CodexAnalysis.ps1'
        $state = Join-Path $testRoot 'retry-state.txt'
        $systems = @($reviewConfig.systems | ForEach-Object {
            [ordered]@{ system_id = [string]$_; status = 'ok'; summary = 'fixture'; coverage_gaps = @() }
        })
        $valid = [ordered]@{
            overall_status = 'ok'
            executive_summary = 'Fixture analysis succeeded.'
            systems = $systems
            findings = @()
            watch_items = @()
            notable_events = @()
            coverage_gaps = @()
        } | ConvertTo-Json -Depth 8 -Compress
        $env:HOMELAB_FAKE_ANALYZER_MODE = 'fail_once'
        $env:HOMELAB_FAKE_ANALYZER_STATE = $state
        $env:HOMELAB_FAKE_ANALYZER_JSON = $valid
        $script:CodexExecutable = $fake
        $script:MaximumAnalysisAttempts = 2
        $script:SkipAiAnalysis = $false

        $analysis = Invoke-AiAnalysis
        $analysis.overall_status | Should Be 'ok'
        @($script:AnalysisAttempts).Count | Should Be 2
        $script:AnalysisAttempts[0].succeeded | Should Be $false
        $script:AnalysisAttempts[1].succeeded | Should Be $true
        $script:AnalysisStatus | Should Be 'succeeded'
        @(Get-ChildItem -LiteralPath $runtimeRoot -Filter "daily-log-review-input-$runId.json").Count | Should Be 1
    }

    It 'returns zero findings after two analyzer failures' {
        Reset-DailyReviewTestState
        Add-SourceLines -SystemId 'proxmox' -Source 'fixture' -Lines @('2026-08-25 12:00:00 CRITICAL simulated failure')
        $env:HOMELAB_FAKE_ANALYZER_MODE = 'always_fail'
        $env:HOMELAB_FAKE_ANALYZER_STATE = (Join-Path $testRoot 'failure-state.txt')
        $env:HOMELAB_FAKE_ANALYZER_JSON = '{}'
        $script:CodexExecutable = Join-Path $repositoryRoot 'test\fixtures\Fake-CodexAnalysis.ps1'
        $script:MaximumAnalysisAttempts = 2
        $script:SkipAiAnalysis = $false

        $analysis = Invoke-AiAnalysis
        @($script:AnalysisAttempts).Count | Should Be 2
        @($analysis.findings).Count | Should Be 0
        $analysis.overall_status | Should Be 'unknown'
        $script:AnalysisStatus | Should Be 'fallback_zero_findings'
    }

    It 'publishes nonempty artifacts and a verifiable relative-path manifest' {
        Reset-DailyReviewTestState
        Add-SourceLines -SystemId 'proxmox' -Source 'fixture' -Lines @()
        $analysis = New-FallbackAnalysis -Reason 'publication fixture'
        $reports = Write-Reports -Analysis $analysis -KnowledgeRecorded $true -RequiredCoverageOk $true
        $manifest = Get-Content -Raw -LiteralPath $reports.LatestManifest | ConvertFrom-Json
        $manifest.run_id | Should Be $runId
        $manifest.publication_status | Should Be 'succeeded'
        $manifest.required_coverage_ok | Should Be $true
        $expectedManifestHash = (Get-Content -Raw -LiteralPath $reports.LatestManifestChecksum).Trim()
        (Get-FileHash -LiteralPath $reports.LatestManifest -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $expectedManifestHash
        @($manifest.artifacts).Count | Should Be 4
        foreach ($artifact in @($manifest.artifacts)) {
            [IO.Path]::IsPathRooted([string]$artifact.relative_path) | Should Be $false
            $artifactPath = Join-Path $reportRoot ([string]$artifact.relative_path)
            (Test-Path -LiteralPath $artifactPath -PathType Leaf) | Should Be $true
            (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be ([string]$artifact.sha256)
        }
    }

    It 'validates registry uniqueness, adapter versions and enforced timeouts' {
        $approved = [ordered]@{}
        foreach ($collector in @($reviewConfig.collectors)) { $approved[[string]$collector.function] = $true }
        { Assert-CollectorRegistry -Collectors @($reviewConfig.collectors) -ApprovedCollectors $approved } | Should Not Throw
        $invalid = @($reviewConfig.collectors | ForEach-Object {
            [pscustomobject]@{
                id = [string]$_.id
                system_id = [string]$_.system_id
                function = [string]$_.function
                enabled = [bool]$_.enabled
                required = [bool]$_.required
                read_only = [bool]$_.read_only
                timeout_seconds = [int]$_.timeout_seconds
                adapter_version = [int]$_.adapter_version
            }
        })
        $invalid[1].id = $invalid[0].id
        $threw = $false
        try { Assert-CollectorRegistry -Collectors $invalid -ApprovedCollectors $approved }
        catch { $threw = $true }
        $threw | Should Be $true
    }

    It 'summarizes structured QNAP and Minecraft health without raw logs' {
        $qnapLines = @(Convert-QnapDiagnosticToLines ([pscustomobject]@{
            FailedRaidMembers = @()
            StorageIssues = @()
            RootAccess = $true
            OverallStatus = 'critical'
        }))
        $qnapLines.Count | Should Be 1
        $qnapLines[0] | Should Match 'critical overall status'

        $minecraftLines = @(Convert-MinecraftDiagnosticToLines ([pscustomobject]@{
            command_status = @()
            signals = [pscustomobject]@{
                container_oom_killed = $true
                container_not_running = $true
                container_exit_code = 137
                recent_kernel_faults = 2
                recent_application_errors = 0
            }
        }))
        ($minecraftLines -join ' ') | Should Match 'OOM-killed'
        ($minecraftLines -join ' ') | Should Match 'exit code 137'
        ($minecraftLines -join ' ') | Should Not Match 'password|token|authorization'
    }

    It 'streams multiline SSH scripts through explicit process stdin unchanged' {
        Reset-DailyReviewTestState
        $previousSshHelper = $script:sshHelper
        try {
            $script:sshHelper = Join-Path $repositoryRoot 'test\fixtures\Fake-SshStdin.py'
            $payload = 'WARNING pipe | dollar $VALUE' + "`n" + 'ERROR quoted "value"'
            Invoke-SshSource -SystemId 'unifi' -Source 'stdin-fixture' -HostName 'fixture' -Port 22 `
                -UserName 'fixture' -Command $payload -CommandFromStdin
            @($script:Coverage).Count | Should Be 1
            $script:Coverage[0].lines_read | Should Be 2
            @($script:Events).Count | Should Be 2
            ($script:Events.message -join ' ') | Should Match '\$VALUE'
        }
        finally {
            $script:sshHelper = $previousSshHelper
        }
    }

    It 'rejects sharing stdin between an SSH script and a password' {
        $knownHostsPath = Join-Path $env:USERPROFILE '.ssh\known_hosts'
        $output = @('do-not-print-this-value' | & $python (Join-Path $repositoryRoot 'scripts\Invoke-SshCommand.py') `
            --host fixture --user fixture --known-hosts $knownHostsPath --script-stdin --password-stdin 2>&1)
        $LASTEXITCODE | Should Be 1
        ($output -join ' ') | Should Match 'cannot both be read'
        ($output -join ' ') | Should Not Match 'do-not-print-this-value'
    }

    It 'enforces an isolated collector timeout and imports only structured results' {
        Reset-DailyReviewTestState
        $fixtureScript = Join-Path $repositoryRoot 'test\fixtures\Fake-DailyCollector.ps1'
        $collector = [pscustomobject]@{ function = 'Invoke-FixtureCollector'; timeout_seconds = 5 }
        Remove-Item Env:HOMELAB_FAKE_COLLECTOR_DELAY_SECONDS -ErrorAction SilentlyContinue
        Invoke-IsolatedCollector -Collector $collector -ScriptPath $fixtureScript
        @($script:Events).Count | Should Be 1
        @($script:Coverage).Count | Should Be 1

        $env:HOMELAB_FAKE_COLLECTOR_DELAY_SECONDS = '3'
        $collector.timeout_seconds = 1
        $timedOut = $false
        try { Invoke-IsolatedCollector -Collector $collector -ScriptPath $fixtureScript }
        catch { $timedOut = $_.Exception.Message -match 'configured timeout' }
        finally { Remove-Item Env:HOMELAB_FAKE_COLLECTOR_DELAY_SECONDS -ErrorAction SilentlyContinue }
        $timedOut | Should Be $true
    }
}

if ($null -eq $previousLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocalAppData }
if ($null -eq $previousAnalyzerMode) { Remove-Item Env:HOMELAB_FAKE_ANALYZER_MODE -ErrorAction SilentlyContinue } else { $env:HOMELAB_FAKE_ANALYZER_MODE = $previousAnalyzerMode }
if ($null -eq $previousAnalyzerState) { Remove-Item Env:HOMELAB_FAKE_ANALYZER_STATE -ErrorAction SilentlyContinue } else { $env:HOMELAB_FAKE_ANALYZER_STATE = $previousAnalyzerState }
if ($null -eq $previousAnalyzerJson) { Remove-Item Env:HOMELAB_FAKE_ANALYZER_JSON -ErrorAction SilentlyContinue } else { $env:HOMELAB_FAKE_ANALYZER_JSON = $previousAnalyzerJson }
if ((Resolve-Path $testRoot).Path.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
