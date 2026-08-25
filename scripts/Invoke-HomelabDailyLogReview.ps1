[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [int]$LookbackHours = 24,

    [switch]$SkipAiAnalysis,

    [ValidateRange(1, 2)]
    [int]$MaximumAnalysisAttempts = 2,

    [string]$CodexExecutable,

    [string]$RuntimeDirectory,

    [string]$ReportDirectory,

    [switch]$SkipKnowledgeRecording,

    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'CodexAdmin.Common.psm1') -Force
$dailyReviewScriptPath = [IO.Path]::GetFullPath($PSCommandPath)
$inventory = Get-Content -Raw (Resolve-CodexAdminDataPath -RepositoryRoot $repoRoot -RelativePath 'inventory\services.json') | ConvertFrom-Json
$accessProfiles = Get-Content -Raw (Resolve-CodexAdminDataPath -RepositoryRoot $repoRoot -RelativePath 'inventory\access-profiles.json') | ConvertFrom-Json
$reviewConfig = Get-Content -Raw (Resolve-CodexAdminDataPath -RepositoryRoot $repoRoot -RelativePath 'config\daily-log-review.json') | ConvertFrom-Json
$runtimeRoot = if ($RuntimeDirectory) { [IO.Path]::GetFullPath($RuntimeDirectory) } else { Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab\daily-log-review' }
$reportRoot = if ($ReportDirectory) { [IO.Path]::GetFullPath($ReportDirectory) } else { Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab\reports' }
$availabilityRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab\availability'
$store = (Resolve-Path (Join-Path $repoRoot 'apps\secret-ui\backend\SecretUiStore.ps1')).Path
$sshHelper = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-SshCommand.py')).Path
$python = (Get-Command python.exe -ErrorAction Stop).Source
$node = (Get-Command node.exe -ErrorAction Stop).Source
$knowledgeCli = (Resolve-Path (Join-Path $repoRoot 'mcp\homelab-admin\build\cli.js')).Path
$identityFile = Join-Path $env:USERPROFILE '.ssh\codex_admin_ed25519'
$knownHosts = Join-Path $env:USERPROFILE '.ssh\known_hosts'
$startedAt = Get-Date
$since = $startedAt.AddHours(-$LookbackHours)
$sinceEpoch = [DateTimeOffset]$since
$sinceEpoch = $sinceEpoch.ToUnixTimeSeconds()
$runId = $startedAt.ToString('yyyyMMdd-HHmmss')
$maximumEventsPerSource = [int]$reviewConfig.maximum_selected_events_per_source
$watchWindowDays = [Math]::Max(1, [Math]::Min(365, [int]$reviewConfig.watch_window_days))

New-Item -ItemType Directory -Force -Path $runtimeRoot, $reportRoot | Out-Null

$script:Events = [System.Collections.Generic.List[object]]::new()
$script:Coverage = [System.Collections.Generic.List[object]]::new()
$script:Stages = [System.Collections.Generic.List[object]]::new()
$script:AnalysisAttempts = [System.Collections.Generic.List[object]]::new()
$script:AnalysisStatus = 'pending'
$script:AnalysisSkipReason = $null

function Invoke-TrackedStage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $stage = [ordered]@{
        name = $Name
        status = 'running'
        started_at = (Get-Date).ToString('o')
        completed_at = $null
        error = $null
    }
    $stageRecord = [pscustomobject]$stage
    $script:Stages.Add($stageRecord)
    try {
        $value = & $Action
        $stageRecord.status = 'succeeded'
        $value
    }
    catch {
        $stageRecord.status = 'failed'
        $stageRecord.error = Protect-LogText $_.Exception.Message
        throw
    }
    finally {
        $stageRecord.completed_at = (Get-Date).ToString('o')
    }
}

function Protect-LogText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' '
    $text = $text -replace '(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', '[PRIVATE KEY REDACTED]'
    $text = $text -replace '(?i)\botpauth://\S+', '[TOTP URI REDACTED]'
    $text = $text -replace '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}', 'Bearer [REDACTED]'
    $text = $text -replace '(?i)\bPVEAPIToken\s*=\s*[^\s,;]+', 'PVEAPIToken=[REDACTED]'
    $text = $text -replace '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b', '[JWT REDACTED]'
    $text = $text -replace '(?i)\b(authorization|x-api-key|api[_ -]?key|token|password|passwd|passphrase|secret|cookie|set-cookie|recovery[_ -]?code)\s*[:=]\s*[^\s,;]+', '$1=[REDACTED]'
    $text = $text -replace '(?i)([?&](?:access_token|api_key|apikey|token|key|password|secret|auth|code)=)[^&\s]+', '$1[REDACTED]'
    $text = $text -replace '(?i)(https?://)[^/@\s:]+:[^/@\s]+@', '$1[USERINFO REDACTED]@'
    $text = $text.Trim()
    if ($text.Length -gt 1200) { $text = $text.Substring(0, 1200) + '…' }
    $text
}

function Protect-Object {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Protect-LogText $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $Value.Keys) { $map[$key] = Protect-Object $Value[$key] }
        return [pscustomobject]$map
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        # Unary comma prevents PowerShell's success pipeline from collapsing an empty
        # collection into $null while recursively sanitizing analysis payloads.
        return ,@($Value | ForEach-Object { Protect-Object $_ })
    }
    if ($Value.PSObject -and @($Value.PSObject.Properties).Count -gt 0 -and
        $Value -isnot [ValueType]) {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = Protect-Object $property.Value
        }
        return [pscustomobject]$map
    }
    $Value
}

function Get-SeverityHint {
    param([Parameter(Mandatory)][string]$Text)

    if ($Text -match '(?i)\b(emerg|alert|panic|fatal|critical|crit|corrupt|segfault|out of memory|oom-kill|disk full|no space left|I/O error)\b') { return 'critical' }
    if ($Text -match '(?i)\b(error|err|failed|failure|unreachable|unauthorized|denied|timeout|timed out|crash|offline|degraded)\b') { return 'high' }
    if ($Text -match '(?i)\b(warning|warn|certificate|tls|handshake|disconnect|flap|backup|snapshot|reboot|shutdown|restart|update|upgrade|adopt)\b') { return 'medium' }
    'info'
}

function Get-DeduplicationKey {
    param([Parameter(Mandatory)][string]$Text)

    $key = $Text.ToLowerInvariant()
    $key = $key -replace '^\s*\d{4}-\d{2}-\d{2}[t ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:z|[+-]\d{2}:?\d{2})?\s*', ''
    $key = $key -replace '\b\d{1,3}(?:\.\d{1,3}){3}\b', '<ip>'
    $key = $key -replace '\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b', '<mac>'
    $key = $key -replace '\b[0-9a-f]{16,}\b', '<id>'
    $key = $key -replace '\b\d{4,}\b', '<n>'
    $key = $key -replace '\s+', ' '
    $key.Trim()
}

function Test-LogLineInWindow {
    param([Parameter(Mandatory)][string]$Text)

    $match = [regex]::Match($Text, '^\s*(\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}:\d{2})')
    if (-not $match.Success) { return $true }
    $formats = @('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-ddTHH:mm:ss', 'yyyy/MM/dd HH:mm:ss')
    $parsed = [datetime]::MinValue
    foreach ($format in $formats) {
        if ([datetime]::TryParseExact(
            $match.Groups[1].Value,
            $format,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeLocal,
            [ref]$parsed
        )) {
            return $parsed -ge $since.AddMinutes(-5) -and $parsed -le $startedAt.AddMinutes(5)
        }
    }
    $true
}

function Add-SyntheticEvent {
    param(
        [Parameter(Mandatory)][string]$SystemId,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('critical', 'high', 'medium', 'info')]
        [string]$Severity = 'info',
        [AllowNull()][string]$Timestamp = $null,
        [int]$Occurrences = 1
    )

    $script:Events.Add([pscustomobject]@{
        system_id = $SystemId
        source = $Source
        timestamp = $Timestamp
        severity_hint = $Severity
        occurrences = [Math]::Max(1, $Occurrences)
        message = Protect-LogText $Message
    })
}

function Add-SourceLines {
    param(
        [Parameter(Mandatory)][string]$SystemId,
        [Parameter(Mandatory)][string]$Source,
        [AllowEmptyCollection()][object[]]$Lines,
        [bool]$Success = $true,
        [AllowNull()][string]$ErrorMessage = $null
    )

    $rawLines = @($Lines)
    $selected = [ordered]@{}
    foreach ($lineValue in $rawLines) {
        $line = Protect-LogText $lineValue
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if (-not (Test-LogLineInWindow $line)) { continue }
        $severity = Get-SeverityHint $line
        if ($severity -eq 'info') { continue }
        $key = "$severity|$(Get-DeduplicationKey $line)"
        if ($selected.Contains($key)) {
            $selected[$key].occurrences++
        }
        elseif ($selected.Count -lt $maximumEventsPerSource) {
            $selected[$key] = [pscustomobject]@{ severity = $severity; line = $line; occurrences = 1 }
        }
    }
    foreach ($item in $selected.Values) {
        Add-SyntheticEvent -SystemId $SystemId -Source $Source -Message $item.line `
            -Severity $item.severity -Occurrences $item.occurrences
    }
    $safeError = if ($ErrorMessage) { Protect-LogText $ErrorMessage } else { $null }
    $script:Coverage.Add([pscustomobject]@{
        system_id = $SystemId
        source = $Source
        success = $Success
        lines_read = $rawLines.Count
        selected_events = $selected.Count
        error = $safeError
    })
    if (-not $Success) {
        Add-SyntheticEvent -SystemId $SystemId -Source $Source `
            -Message "Logquelle nicht lesbar: $safeError" -Severity high
    }
}

function Invoke-SshSource {
    param(
        [Parameter(Mandatory)][string]$SystemId,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Command,
        [string]$IdentityPath = $identityFile,
        [string]$KnownHostsPath = $knownHosts,
        [switch]$CommandFromStdin
    )

    try {
        if ($CommandFromStdin) {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $python
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @(
                $sshHelper,
                '--host', $HostName,
                '--port', [string]$Port,
                '--user', $UserName,
                '--identity', $IdentityPath,
                '--known-hosts', $KnownHostsPath,
                '--script-stdin'
            )) {
                $startInfo.ArgumentList.Add([string]$argument)
            }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $startInfo
            try {
                if (-not $process.Start()) { throw 'SSH helper process could not be started.' }
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                $process.StandardInput.Write($Command)
                $process.StandardInput.Close()
                $process.WaitForExit()
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
                $exitCode = $process.ExitCode
                $lines = @(
                    @($stdout -split '\r?\n')
                    @($stderr -split '\r?\n')
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            }
            finally {
                $process.Dispose()
            }
        }
        else {
            $lines = @(& $python $sshHelper `
                --host $HostName `
                --port $Port `
                --user $UserName `
                --identity $IdentityPath `
                --known-hosts $KnownHostsPath `
                --command $Command 2>&1)
            $exitCode = $LASTEXITCODE
        }
        if ($exitCode -eq 0) {
            Add-SourceLines -SystemId $SystemId -Source $Source -Lines $lines
        }
        else {
            $errorText = (@($lines | Select-Object -Last 3) -join ' ')
            Add-SourceLines -SystemId $SystemId -Source $Source -Lines @() `
                -Success $false -ErrorMessage "SSH exit code $exitCode. $errorText"
        }
    }
    catch {
        Add-SourceLines -SystemId $SystemId -Source $Source -Lines @() `
            -Success $false -ErrorMessage $_.Exception.Message
    }
}

function Get-VaultClipboardValue {
    param([Parameter(Mandatory)][string]$RecordId)

    & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $store `
        -Action Copy -Id $RecordId -ClearAfterSeconds 5 | Out-Null
    $value = (Get-Clipboard -Raw).TrimEnd("`r", "`n")
    Set-Clipboard -Value ''
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'Vault value is unavailable.' }
    $value
}

function Get-AccessCredentialRef {
    param([Parameter(Mandatory)][string]$ProfileId)

    $profile = @($accessProfiles.profiles | Where-Object id -eq $ProfileId)
    if ($profile.Count -ne 1) { throw "Unknown or duplicate access profile: $ProfileId" }
    [string]$profile[0].credential_ref
}

function Initialize-PinnedHttpClientType {
    if ('HomelabDailyPinnedClient' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;

public static class HomelabDailyPinnedClient {
    public static HttpClient Create(string expectedSha256) {
        var handler = new HttpClientHandler();
        handler.AutomaticDecompression = DecompressionMethods.GZip |
            DecompressionMethods.Deflate | DecompressionMethods.Brotli;
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

function Invoke-ProxmoxCollection {
    $systemId = 'proxmox'
    $client = $null
    $tokenValue = $null
    try {
        Initialize-PinnedHttpClientType
        $credentialRef = Get-AccessCredentialRef 'proxmox-api-admin'
        $tokenValue = Get-VaultClipboardValue $credentialRef
        $service = $inventory.services.proxmox
        $client = [HomelabDailyPinnedClient]::Create([string]$service.certificate_sha256)
        $client.DefaultRequestHeaders.TryAddWithoutValidation(
            'Authorization', "PVEAPIToken=codex-admin@pve!codex=$tokenValue"
        ) | Out-Null
        $tokenValue = $null

        function Get-PveData([string]$RelativeUri) {
            $response = $client.GetAsync(([string]$service.base_url + $RelativeUri)).GetAwaiter().GetResult()
            try {
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) {
                    throw "Proxmox API returned HTTP $([int]$response.StatusCode)."
                }
                (ConvertFrom-Json $body).data
            }
            finally { $response.Dispose() }
        }

        try {
            $journal = @(Get-PveData "/api2/json/nodes/proxmox/journal?since=$sinceEpoch")
            Add-SourceLines -SystemId $systemId -Source 'pve-node-journal' -Lines $journal
        }
        catch {
            Add-SourceLines -SystemId $systemId -Source 'pve-node-journal' -Lines @() `
                -Success $false -ErrorMessage $_.Exception.Message
        }

        try {
            $tasks = @(Get-PveData "/api2/json/nodes/proxmox/tasks?start=0&limit=500&since=$sinceEpoch")
            $taskLines = foreach ($task in $tasks) {
                $exitProperty = $task.PSObject.Properties['exitstatus']
                if ($exitProperty -and $exitProperty.Value -and [string]$exitProperty.Value -ne 'OK') {
                    $startProperty = $task.PSObject.Properties['starttime']
                    $taskTime = if ($startProperty -and $startProperty.Value) {
                        [DateTimeOffset]::FromUnixTimeSeconds([long]$startProperty.Value).ToLocalTime().ToString('s')
                    } else { 'unknown-time' }
                    $typeValue = if ($task.PSObject.Properties['type']) { $task.type } else { 'unknown' }
                    $guestValue = if ($task.PSObject.Properties['id']) { $task.id } else { 'none' }
                    $userValue = if ($task.PSObject.Properties['user']) { $task.user } else { 'unknown' }
                    "$taskTime task=$typeValue vmid=$guestValue user=$userValue exit=$($exitProperty.Value)"
                }
            }
            Add-SourceLines -SystemId $systemId -Source 'pve-tasks' -Lines @($taskLines)
        }
        catch {
            Add-SourceLines -SystemId $systemId -Source 'pve-tasks' -Lines @() `
                -Success $false -ErrorMessage $_.Exception.Message
        }

        try {
            $status = Get-PveData '/api2/json/nodes/proxmox/status'
            $nodeStatusProperty = $status.PSObject.Properties['status']
            if ($nodeStatusProperty -and [string]$nodeStatusProperty.Value -ne 'online') {
                Add-SyntheticEvent -SystemId $systemId -Source 'pve-node-status' `
                    -Severity critical -Message "Proxmox node status is $($nodeStatusProperty.Value)."
            }
            Add-SourceLines -SystemId $systemId -Source 'pve-node-status' -Lines @()
        }
        catch {
            Add-SourceLines -SystemId $systemId -Source 'pve-node-status' -Lines @() `
                -Success $false -ErrorMessage $_.Exception.Message
        }

        try {
            $storage = @(Get-PveData '/api2/json/nodes/proxmox/storage')
            foreach ($item in $storage) {
                if ($item.enabled -eq 0 -or [string]$item.active -eq '0') {
                    Add-SyntheticEvent -SystemId $systemId -Source 'pve-storage' `
                        -Severity high -Message "Storage $($item.storage) is inactive or disabled."
                }
                if ($item.total -and $item.used) {
                    $usedPercent = [Math]::Round((100 * [double]$item.used / [double]$item.total), 1)
                    if ($usedPercent -ge 85) {
                        $severity = if ($usedPercent -ge 95) { 'critical' } else { 'high' }
                        Add-SyntheticEvent -SystemId $systemId -Source 'pve-storage' `
                            -Severity $severity -Message "Storage $($item.storage) usage is $usedPercent percent."
                    }
                }
            }
            Add-SourceLines -SystemId $systemId -Source 'pve-storage' -Lines @()
        }
        catch {
            Add-SourceLines -SystemId $systemId -Source 'pve-storage' -Lines @() `
                -Success $false -ErrorMessage $_.Exception.Message
        }

        foreach ($kind in @('qemu', 'lxc')) {
            try {
                $guests = @(Get-PveData "/api2/json/nodes/proxmox/$kind")
                foreach ($guest in $guests) {
                    if ([string]$guest.status -ne 'running') {
                        Add-SyntheticEvent -SystemId $systemId -Source "pve-$kind-state" `
                            -Severity info -Message "$kind guest $($guest.vmid) is $($guest.status)."
                    }
                }
                Add-SourceLines -SystemId $systemId -Source "pve-$kind-state" -Lines @()
            }
            catch {
                Add-SourceLines -SystemId $systemId -Source "pve-$kind-state" -Lines @() `
                    -Success $false -ErrorMessage $_.Exception.Message
            }
        }
    }
    catch {
        Add-SourceLines -SystemId $systemId -Source 'proxmox-api' -Lines @() `
            -Success $false -ErrorMessage $_.Exception.Message
    }
    finally {
        if ($client) { $client.Dispose() }
        $tokenValue = $null
        Set-Clipboard -Value ''
    }
}

function Invoke-HomeAssistantCollection {
    $hostName = ([uri]$inventory.services.home_assistant.base_url).Host
    Invoke-SshSource -SystemId 'home_assistant' -Source 'ha-core' -HostName $hostName `
        -Port 22 -UserName 'root' -Command 'ha core logs --lines 5000'
    Invoke-SshSource -SystemId 'home_assistant' -Source 'ha-supervisor' -HostName $hostName `
        -Port 22 -UserName 'root' -Command 'ha supervisor logs --lines 3000'
    Invoke-SshSource -SystemId 'home_assistant' -Source 'ha-host' -HostName $hostName `
        -Port 22 -UserName 'root' -Command 'ha host logs --lines 3000'
    Invoke-SshSource -SystemId 'home_assistant' -Source 'haos-journal' -HostName $hostName `
        -Port 22222 -UserName 'root' `
        -Command "journalctl --since '@$sinceEpoch' -p warning..alert --no-pager -o short-iso -n 10000"
}

function Test-AvailabilityDiagnosticsHealthy {
    param([AllowNull()][object]$Diagnostics)

    if ($null -eq $Diagnostics) { return $false }
    foreach ($name in @('dns', 'public_tcp', 'local_reverse_proxy')) {
        $property = $Diagnostics.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { return $false }
        $outcome = $property.Value.PSObject.Properties['outcome']
        if ($null -eq $outcome -or [string]$outcome.Value -ne 'ok') { return $false }
    }
    $true
}

function Invoke-HomeAssistantAvailabilityCollection {
    $systemId = 'home_assistant'
    $source = 'ha-dual-endpoint-availability'
    $records = [System.Collections.Generic.List[object]]::new()
    $invalidLines = 0

    try {
        if (-not (Test-Path -LiteralPath $availabilityRoot -PathType Container)) {
            throw 'Das Verfügbarkeitsprotokollverzeichnis fehlt.'
        }

        $files = @(Get-ChildItem -LiteralPath $availabilityRoot -Filter 'home-assistant-availability-*.jsonl' -File |
            Where-Object { $_.LastWriteTime -ge $since.AddDays(-1) } |
            Sort-Object Name)
        if ($files.Count -eq 0) {
            throw 'Es wurde kein Home-Assistant-Verfügbarkeitsprotokoll gefunden.'
        }

        foreach ($file in $files) {
            foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding utf8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $item = $line | ConvertFrom-Json -ErrorAction Stop
                    if (-not $item.PSObject.Properties['observed_at'] -or
                        -not $item.PSObject.Properties['correlation'] -or
                        -not $item.PSObject.Properties['external'] -or
                        -not $item.PSObject.Properties['internal']) {
                        throw 'Pflichtfelder fehlen.'
                    }
                    $observedAt = [DateTimeOffset]::Parse(
                        [string]$item.observed_at,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    )
                    if ($observedAt -lt [DateTimeOffset]$since -or
                        $observedAt -gt [DateTimeOffset]$startedAt.AddMinutes(5)) {
                        continue
                    }
                    if (-not $item.external.PSObject.Properties['online'] -or
                        -not $item.internal.PSObject.Properties['online']) {
                        throw 'Endpointstatus fehlt.'
                    }
                    $schemaVersion = if ($item.PSObject.Properties['schema_version']) {
                        [int]$item.schema_version
                    }
                    else {
                        1
                    }
                    if ($schemaVersion -notin @(1, 2)) {
                        throw 'Nicht unterstützte Schema-Version.'
                    }
                    $externalProbeValid = $true
                    $internalProbeValid = $true
                    if ($schemaVersion -ge 2) {
                        if (-not $item.external.PSObject.Properties['probe_valid'] -or
                            -not $item.internal.PSObject.Properties['probe_valid']) {
                            throw 'Probe-Gültigkeitsstatus fehlt.'
                        }
                        $externalProbeValid = [bool]$item.external.probe_valid
                        $internalProbeValid = [bool]$item.internal.probe_valid
                    }
                    $pathDiagnostics = if ($item.PSObject.Properties['path_diagnostics']) {
                        $item.path_diagnostics
                    }
                    else {
                        $null
                    }
                    $legacyProbeError = $schemaVersion -eq 1 -and
                        [string]$item.correlation -eq 'external_path_failure' -and
                        [string]$item.external.outcome -eq 'transport_error' -and
                        [bool]$item.internal.online -and
                        (Test-AvailabilityDiagnosticsHealthy $pathDiagnostics)
                    if ($legacyProbeError) { $externalProbeValid = $false }
                    $effectiveCorrelation = if (-not $externalProbeValid -or -not $internalProbeValid) {
                        'probe_error'
                    }
                    else {
                        [string]$item.correlation
                    }
                    $records.Add([pscustomobject]@{
                        observed_at = $observedAt
                        schema_version = $schemaVersion
                        correlation = $effectiveCorrelation
                        probe_error = $effectiveCorrelation -eq 'probe_error'
                        external = $item.external
                        internal = $item.internal
                        path_diagnostics = $pathDiagnostics
                    })
                }
                catch {
                    $invalidLines++
                }
            }
        }

        $ordered = @($records | Sort-Object observed_at)
        if ($ordered.Count -eq 0) {
            throw 'Im Prüfzeitraum sind keine gültigen Verfügbarkeitsmessungen vorhanden.'
        }

        $selectedEvents = 0
        $latest = $ordered[-1]
        $latestAgeMinutes = ([DateTimeOffset]$startedAt - $latest.observed_at).TotalMinutes
        $probeErrors = @($ordered | Where-Object probe_error)
        $validMeasurements = @($ordered | Where-Object { -not $_.probe_error })
        $coverageErrors = [System.Collections.Generic.List[string]]::new()
        if ($latestAgeMinutes -gt 3) {
            $coverageErrors.Add(
                ('Die jüngste Verfügbarkeitsmessung ist {0:N1} Minuten alt; erwartet werden höchstens 3 Minuten.' -f $latestAgeMinutes)
            )
        }
        if ($validMeasurements.Count -eq 0) {
            $coverageErrors.Add('Im Prüfzeitraum war keine gültige Endpointmessung verfügbar.')
        }
        if ($probeErrors.Count -gt 0) {
            $coverageErrors.Add(
                ('{0} Messung(en) enthielten einen Fehler des Prüfwerkzeugs und wurden nicht als Home-Assistant-Ausfall gewertet.' -f $probeErrors.Count)
            )
        }
        $coverageSuccess = $coverageErrors.Count -eq 0
        $coverageError = if ($coverageSuccess) { $null } else { $coverageErrors -join ' ' }

        $bothOnlineCount = @($validMeasurements | Where-Object correlation -eq 'both_online').Count
        $externalOnlineCount = @($validMeasurements | Where-Object { [bool]$_.external.online }).Count
        $internalOnlineCount = @($validMeasurements | Where-Object { [bool]$_.internal.online }).Count
        $externalLatencies = @($validMeasurements | Where-Object { $null -ne $_.external.latency_ms } | ForEach-Object { [double]$_.external.latency_ms })
        $internalLatencies = @($validMeasurements | Where-Object { $null -ne $_.internal.latency_ms } | ForEach-Object { [double]$_.internal.latency_ms })
        $externalMaximum = if ($externalLatencies.Count -gt 0) { [Math]::Round(($externalLatencies | Measure-Object -Maximum).Maximum) } else { $null }
        $internalMaximum = if ($internalLatencies.Count -gt 0) { [Math]::Round(($internalLatencies | Measure-Object -Maximum).Maximum) } else { $null }
        Add-SyntheticEvent -SystemId $systemId -Source $source -Severity info `
            -Timestamp $latest.observed_at.ToString('o') -Message (
                '{0}/{1} Minutenmessungen waren gültig: beide Endpunkte online {2}/{0}, extern online {3}/{0}, intern online {4}/{0}; maximale Antwortzeit extern {5} ms, intern {6} ms.' -f
                $validMeasurements.Count, $ordered.Count, $bothOnlineCount, $externalOnlineCount, $internalOnlineCount, $externalMaximum, $internalMaximum
            )
        $selectedEvents++

        foreach ($state in @('external_path_failure', 'both_unavailable', 'internal_reference_failure')) {
            $matches = @($validMeasurements | Where-Object correlation -eq $state)
            if ($matches.Count -eq 0) { continue }
            $first = $matches[0].observed_at.ToString('o')
            $last = $matches[-1].observed_at.ToString('o')
            $message = switch ($state) {
                'external_path_failure' {
                    $diagnostics = @($matches | Where-Object {
                        $null -ne $_.path_diagnostics -and
                        $null -ne $_.path_diagnostics.PSObject.Properties['dns'] -and
                        $null -ne $_.path_diagnostics.PSObject.Properties['public_tcp'] -and
                        $null -ne $_.path_diagnostics.PSObject.Properties['local_reverse_proxy']
                    })
                    $diagnosticSuffix = ''
                    if ($diagnostics.Count -gt 0) {
                        $dnsOutcomes = @($diagnostics |
                            Group-Object { [string]$_.path_diagnostics.dns.outcome } |
                            ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
                        $publicTcpOutcomes = @($diagnostics |
                            Group-Object { [string]$_.path_diagnostics.public_tcp.outcome } |
                            ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
                        $localProxyOutcomes = @($diagnostics |
                            Group-Object { [string]$_.path_diagnostics.local_reverse_proxy.outcome } |
                            ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
                        $diagnosticSuffix = (
                            ' Unmittelbare Folgediagnose für {0} Ausfallmessung(en): DNS [{1}], öffentliches TCP/443 [{2}], direkter lokaler Nginx-zu-HA-Pfad [{3}].' -f
                            $diagnostics.Count, $dnsOutcomes, $publicTcpOutcomes, $localProxyOutcomes
                        )
                    }
                    "Der externe Home-Assistant-Pfad war bei $($matches.Count) Minutenmessungen nicht online, während der interne Referenzpfad online war; Zeitraum $first bis $last.$diagnosticSuffix"
                }
                'both_unavailable' {
                    "Externer und interner Home-Assistant-Pfad waren bei $($matches.Count) Minutenmessungen gleichzeitig nicht online; Zeitraum $first bis $last."
                }
                default {
                    "Der interne Home-Assistant-Referenzpfad war bei $($matches.Count) Minutenmessungen nicht online, während der externe Pfad online war; Zeitraum $first bis $last."
                }
            }
            $severity = if ($state -eq 'both_unavailable' -or $matches.Count -ge 3) { 'high' } else { 'medium' }
            Add-SyntheticEvent -SystemId $systemId -Source $source -Severity $severity `
                -Timestamp $matches[-1].observed_at.ToString('o') -Occurrences $matches.Count -Message $message
            $selectedEvents++
        }

        $gapCount = 0
        $maximumGapMinutes = 0.0
        for ($index = 1; $index -lt $ordered.Count; $index++) {
            $gapMinutes = ($ordered[$index].observed_at - $ordered[$index - 1].observed_at).TotalMinutes
            if ($gapMinutes -gt 2.5) {
                $gapCount++
                $maximumGapMinutes = [Math]::Max($maximumGapMinutes, $gapMinutes)
            }
        }
        if ($gapCount -gt 0) {
            $severity = if ($maximumGapMinutes -gt 5) { 'high' } else { 'medium' }
            Add-SyntheticEvent -SystemId $systemId -Source $source -Severity $severity `
                -Occurrences $gapCount -Message (
                    'Das minutenweise Verfügbarkeitsprotokoll enthält {0} Messlücke(n) über 2,5 Minuten; größte Lücke {1:N1} Minuten.' -f
                    $gapCount, $maximumGapMinutes
                )
            $selectedEvents++
        }

        if ($invalidLines -gt 0) {
            Add-SyntheticEvent -SystemId $systemId -Source $source -Severity medium `
                -Occurrences $invalidLines -Message "$invalidLines ungültige oder unvollständige Zeile(n) im Verfügbarkeitsprotokoll wurden verworfen."
            $selectedEvents++
        }
        if ($probeErrors.Count -gt 0) {
            Add-SyntheticEvent -SystemId $systemId -Source $source -Severity high `
                -Timestamp $probeErrors[-1].observed_at.ToString('o') -Occurrences $probeErrors.Count -Message (
                    '{0} Endpointmessung(en) wurden wegen eines Fehlers des Prüfwerkzeugs verworfen. Dies ist eine Abdeckungslücke des Monitors und ausdrücklich kein bestätigter Home-Assistant-Ausfall.' -f $probeErrors.Count
                )
            $selectedEvents++
        }
        if (-not $coverageSuccess) {
            Add-SyntheticEvent -SystemId $systemId -Source $source -Severity high `
                -Timestamp $latest.observed_at.ToString('o') -Message "Verfügbarkeitsmonitor unvollständig: $coverageError"
            $selectedEvents++
        }

        $script:Coverage.Add([pscustomobject]@{
            system_id = $systemId
            source = $source
            success = $coverageSuccess
            lines_read = $ordered.Count + $invalidLines
            selected_events = $selectedEvents
            error = if ($coverageError) { Protect-LogText $coverageError } else { $null }
        })
    }
    catch {
        $safeError = Protect-LogText $_.Exception.Message
        $script:Coverage.Add([pscustomobject]@{
            system_id = $systemId
            source = $source
            success = $false
            lines_read = $records.Count + $invalidLines
            selected_events = 1
            error = $safeError
        })
        Add-SyntheticEvent -SystemId $systemId -Source $source -Severity high `
            -Message "Verfügbarkeitsprotokoll nicht auswertbar: $safeError"
    }
}

function Invoke-ReverseProxyCollection {
    $service = $inventory.services.reverse_proxy
    $hostName = ([uri]$service.ssh_url).Host
    $minutes = $LookbackHours * 60
    Invoke-SshSource -SystemId 'reverse_proxy' -Source 'npm-service-journal' `
        -HostName $hostName -Port 22 -UserName ([string]$service.ssh_user) `
        -Command "sudo -n journalctl --since '@$sinceEpoch' -u npm.service -u openresty.service -p warning..alert --no-pager -o short-iso -n 10000"
    Invoke-SshSource -SystemId 'reverse_proxy' -Source 'npm-failed-units' `
        -HostName $hostName -Port 22 -UserName ([string]$service.ssh_user) `
        -Command 'sudo -n systemctl --failed --no-legend --no-pager'
    Invoke-SshSource -SystemId 'reverse_proxy' -Source 'npm-proxy-error-logs' `
        -HostName $hostName -Port 22 -UserName ([string]$service.ssh_user) `
        -Command "sudo -n find /data/logs -maxdepth 1 -type f -name '*_error.log' -mmin -$minutes -print0 2>/dev/null | xargs -0 -r tail -n 500"
}

function Invoke-UniFiCollection {
    $service = $inventory.services.unifi
    $hostName = ([uri]$service.ssh_url).Host
    $minutes = $LookbackHours * 60
    Invoke-SshSource -SystemId 'unifi' -Source 'unifi-system-journal' `
        -HostName $hostName -Port 22 -UserName ([string]$service.ssh_user) `
        -Command "journalctl --since '@$sinceEpoch' -p warning..alert --no-pager -o short-iso -n 15000"
    Invoke-SshSource -SystemId 'unifi' -Source 'unifi-failed-units' `
        -HostName $hostName -Port 22 -UserName ([string]$service.ssh_user) `
        -Command 'systemctl --failed --no-legend --no-pager'

    $unifiFilesCommand = @'
for f in \
  /data/unifi/logs/server.log \
  /data/unifi/logs/mongod.log \
  /data/unifi/logs/sdwan.log \
  /data/unifi/logs/state.log \
  /data/unifi/logs/tasks.log \
  /var/log/auth.log \
  /var/log/coredns/corednssc.log \
  /var/log/dnscrypt-proxy.log \
  /var/log/nginx/error.log \
  /var/log/poe-event.log \
  /var/log/rabbitmq/rabbitmq-server.error.log \
  /var/log/ulog/threat.log \
  /var/log/unifi_package.log \
  /var/log/updater.log \
  /var/log/wan-diag-dhcp.log \
  /var/log/wan-diag-dhcpv6.log \
  /var/log/wan-diag-ipv6-intf-events.log \
  /var/log/wan-diag-port.log
do
  if [ -f "$f" ] && find "$f" -mmin -__MINUTES__ -print -quit | grep -q .; then
    tail -n 700 "$f" | grep -Eai 'emerg|alert|crit|critical|error|err|failed|failure|fatal|panic|exception|warning|warn|timeout|unreachable|degraded|denied|unauthorized|offline|disconnect|flap|certificate|tls|backup|reboot|shutdown|update|upgrade|threat' || true
  fi
done
'@
    $unifiFilesCommand = $unifiFilesCommand.Replace('__MINUTES__', [string]$minutes)
    Invoke-SshSource -SystemId 'unifi' -Source 'unifi-application-logs' `
        -HostName $hostName -Port 22 -UserName ([string]$service.ssh_user) `
        -Command $unifiFilesCommand -CommandFromStdin
}

function Invoke-PublicRelayCollection {
    $script = @'
set -u
for service in wg-quick@wg0 nftables ssh; do
  state=$(sudo -n systemctl is-active "$service" 2>/dev/null || true)
  if [ "$state" != active ]; then
    printf 'ERROR service %s is %s\n' "$service" "${state:-unknown}"
  fi
done
if ! sudo -n nft -c -f /etc/nftables.conf >/dev/null 2>&1; then
  echo 'ERROR nftables configuration validation failed'
fi
now=$(date +%s)
sudo -n wg show all latest-handshakes 2>/dev/null | awk -v now="$now" '
  BEGIN { peers=0; stale=0 }
  { peers++; if ($2 == 0 || now - $2 > 600) stale++ }
  END {
    if (peers == 0) print "ERROR WireGuard has no peers";
    else if (stale > 0) printf "WARNING WireGuard stale peers=%d total=%d\n", stale, peers;
  }'
journalctl --since '@__SINCE__' -p warning..alert --no-pager -o short-iso -n 10000
'@
    $script = $script.Replace('__SINCE__', [string]$sinceEpoch)
    Invoke-SshSource -SystemId 'public_relay_vps' -Source 'public VPS provider-wireguard-health-and-journal' `
        -HostName '198.51.100.1' -Port 22222 -UserName 'codex-admin' -Command $script `
        -IdentityPath (Join-Path $env:USERPROFILE '.ssh\public_relay_codex_ed25519') `
        -KnownHostsPath (Join-Path $env:USERPROFILE '.ssh\known_hosts_public_relay') -CommandFromStdin
}

function Convert-QnapDiagnosticToLines {
    param([Parameter(Mandatory)][object]$Diagnostic)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($member in @($Diagnostic.FailedRaidMembers)) { $lines.Add("ERROR failed RAID member $member") }
    foreach ($issue in @($Diagnostic.StorageIssues)) { $lines.Add("ERROR storage issue: $issue") }
    if (-not [bool]$Diagnostic.RootAccess) { $lines.Add('WARNING QNAP read-only diagnostic did not obtain root scope') }
    if ([string]$Diagnostic.OverallStatus -eq 'critical' -and $lines.Count -eq 0) {
        $lines.Add('ERROR QNAP read-only diagnostic reported a critical overall status without a categorized storage detail')
    }
    elseif ([string]$Diagnostic.OverallStatus -eq 'warning' -and $lines.Count -eq 0) {
        $lines.Add('WARNING QNAP read-only diagnostic reported a warning overall status')
    }
    @($lines)
}

function Invoke-QnapCollection {
    try {
        $diagnostic = & (Join-Path $PSScriptRoot 'Get-QnapReadOnlyDiagnostics.ps1')
        Add-SourceLines -SystemId 'qnap_nas' -Source 'qnap-read-only-diagnostics' `
            -Lines @(Convert-QnapDiagnosticToLines $diagnostic)
    }
    catch {
        Add-SourceLines -SystemId 'qnap_nas' -Source 'qnap-read-only-diagnostics' -Lines @() `
            -Success $false -ErrorMessage $_.Exception.Message
    }
}

function Convert-MinecraftDiagnosticToLines {
    param([Parameter(Mandatory)][object]$Diagnostic)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($command in @($Diagnostic.command_status | Where-Object { $_.unavailable -or [int]$_.exit_code -ne 0 })) {
        $lines.Add("ERROR Minecraft diagnostic command $($command.name) unavailable=$([bool]$command.unavailable) exit_code=$($command.exit_code)")
    }
    if ($Diagnostic.PSObject.Properties['signals']) {
        $signals = $Diagnostic.signals
        if ([bool]$signals.container_oom_killed) { $lines.Add('CRITICAL Minecraft container reports an OOM-killed state') }
        if ([bool]$signals.container_not_running) { $lines.Add('ERROR Minecraft container is not running') }
        if ([int]$signals.container_exit_code -gt 0) { $lines.Add("ERROR Minecraft container exit code $([int]$signals.container_exit_code)") }
        if ([int]$signals.recent_kernel_faults -gt 0) { $lines.Add("CRITICAL Minecraft guest reported $([int]$signals.recent_kernel_faults) recent kernel or JVM fault line(s)") }
        if ([int]$signals.recent_application_errors -gt 0) { $lines.Add("ERROR Minecraft logs reported $([int]$signals.recent_application_errors) recent application error line(s)") }
    }
    @($lines)
}

function Invoke-MinecraftCollection {
    try {
        $diagnostic = & (Join-Path $PSScriptRoot 'Get-MinecraftGuestDiagnostics.ps1') -NoPersist
        $lines = @(Convert-MinecraftDiagnosticToLines $diagnostic)
        Add-SourceLines -SystemId 'game_server' -Source 'minecraft-read-only-guest-diagnostics' -Lines $lines `
            -Success ([bool]$diagnostic.success) -ErrorMessage $(if ($diagnostic.success) { $null } else { 'At least one read-only guest diagnostic command failed.' })
    }
    catch {
        Add-SourceLines -SystemId 'game_server' -Source 'minecraft-read-only-guest-diagnostics' -Lines @() `
            -Success $false -ErrorMessage $_.Exception.Message
    }
}

function Invoke-WindowsCollection {
    $sources = @(
        @{ Name = 'System'; Source = 'windows-system' },
        @{ Name = 'Application'; Source = 'windows-application' },
        @{ Name = 'Microsoft-Windows-TaskScheduler/Operational'; Source = 'windows-task-scheduler' },
        @{ Name = 'Microsoft-Windows-Windows Defender/Operational'; Source = 'windows-defender' }
    )
    foreach ($entry in $sources) {
        try {
            $records = @(Get-WinEvent -FilterHashtable @{
                LogName = $entry.Name
                StartTime = $since
                Level = 1, 2, 3
            } -ErrorAction Stop | Select-Object -First 3000)
            $lines = foreach ($record in $records) {
                $message = ([string]$record.Message -replace '[\r\n]+', ' ')
                "$($record.TimeCreated.ToString('s')) provider=$($record.ProviderName) id=$($record.Id) level=$($record.LevelDisplayName) $message"
            }
            Add-SourceLines -SystemId 'admin_workstation' -Source $entry.Source -Lines @($lines)
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or
                $_.Exception.Message -like 'No events were found*') {
                Add-SourceLines -SystemId 'admin_workstation' -Source $entry.Source -Lines @()
            }
            else {
                Add-SourceLines -SystemId 'admin_workstation' -Source $entry.Source -Lines @() `
                    -Success $false -ErrorMessage $_.Exception.Message
            }
        }
    }
}

function New-FallbackAnalysis {
    param([Parameter(Mandatory)][string]$Reason)

    $coverageGaps = @($script:Coverage | Where-Object { -not $_.success } | ForEach-Object {
        "$($_.system_id)/$($_.source): $($_.error)"
    })
    $coverageGaps += $Reason
    $enabledSystemIds = @($reviewConfig.collectors | Where-Object enabled | ForEach-Object { [string]$_.system_id } | Sort-Object -Unique)
    $systems = foreach ($systemId in $enabledSystemIds) {
        $sourceRows = @($script:Coverage | Where-Object system_id -eq $systemId)
        $failed = @($sourceRows | Where-Object { -not $_.success }).Count
        [pscustomobject]@{
            system_id = [string]$systemId
            status = if ($failed -gt 0) { 'unknown' } else { 'ok' }
            summary = if ($failed -gt 0) { "$failed Logquellen konnten nicht gelesen werden." } else { 'Logquellen wurden gelesen; intelligente Auswertung ist nicht verfügbar.' }
            coverage_gaps = @($sourceRows | Where-Object { -not $_.success } | ForEach-Object { [string]$_.source })
        }
    }
    $script:AnalysisStatus = 'fallback_zero_findings'
    [pscustomobject]@{
        overall_status = if ($coverageGaps.Count -gt 0) { 'unknown' } else { 'ok' }
        executive_summary = "Die Logsammlung wurde abgeschlossen. $Reason Keine Reparatur wurde durchgeführt."
        systems = @($systems)
        findings = @()
        watch_items = @()
        notable_events = @()
        coverage_gaps = @($coverageGaps)
    }
}

function Get-PriorReviewContext {
    $result = [ordered]@{
        available = $false
        window_days = $watchWindowDays
        observations = @()
        error = $null
    }

    try {
        $raw = @(& $node $knowledgeCli context full 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Knowledge context exited with code $LASTEXITCODE."
        }
        $context = ($raw -join "`n") | ConvertFrom-Json
        $result.observations = @($context.current_observations |
            Where-Object { [string]$_.kind -match '^daily_log_(watch|finding):' } |
            Sort-Object observed_at -Descending |
            Select-Object -First 100 |
            ForEach-Object {
                [pscustomobject]@{
                    system_id = [string]$_.system_id
                    kind = [string]$_.kind
                    status = [string]$_.status
                    summary = Protect-LogText $_.summary
                    observed_at = [string]$_.observed_at
                }
            })
        $result.available = $true
    }
    catch {
        $result.error = Protect-LogText $_.Exception.Message
    }

    [pscustomobject]$result
}

function Invoke-AiAnalysis {
    $inputPath = Join-Path $runtimeRoot 'daily-log-review-input.json'
    $schemaPath = Join-Path $runtimeRoot 'daily-log-analysis.schema.json'
    $snapshotArchivePath = Join-Path $runtimeRoot "daily-log-review-input-$runId.json"
    $promptPath = Join-Path $repoRoot 'prompts\daily-log-review.md'
    Copy-Item -Force (Join-Path $repoRoot 'config\daily-log-analysis.schema.json') $schemaPath

    $snapshot = [pscustomobject]@{
        schema_version = 1
        run_id = $runId
        generated_at = $startedAt.ToString('o')
        lookback_start = $since.ToString('o')
        lookback_hours = $LookbackHours
        mode = 'read_only'
        repair_policy = 'explicit_user_confirmation_required'
        collector_registry = @($reviewConfig.collectors | Where-Object enabled | ForEach-Object {
            [pscustomobject]@{
                id = [string]$_.id
                system_id = [string]$_.system_id
                required = [bool]$_.required
                read_only = [bool]$_.read_only
                adapter_version = [int]$_.adapter_version
            }
        })
        coverage = @($script:Coverage)
        events = @($script:Events)
        prior_review_context = Get-PriorReviewContext
    }
    $snapshotStage = [pscustomobject][ordered]@{
        name = 'snapshot'
        status = 'running'
        started_at = (Get-Date).ToString('o')
        completed_at = $null
        error = $null
    }
    $script:Stages.Add($snapshotStage)
    try {
        $snapshotJson = $snapshot | ConvertTo-Json -Depth 8
        Write-AtomicUtf8File -Path $snapshotArchivePath -Content $snapshotJson | Out-Null
        Write-AtomicUtf8File -Path $inputPath -Content $snapshotJson | Out-Null
        $snapshotStage.status = 'succeeded'
    }
    catch {
        $snapshotStage.status = 'failed'
        $snapshotStage.error = Protect-LogText $_.Exception.Message
        throw
    }
    finally { $snapshotStage.completed_at = (Get-Date).ToString('o') }

    if ($SkipAiAnalysis) {
        $script:AnalysisSkipReason = 'AI-Auswertung wurde für diesen Testlauf übersprungen.'
        return New-FallbackAnalysis -Reason $script:AnalysisSkipReason
    }

    $codexCandidates = if ($CodexExecutable) { @($CodexExecutable) } else { @(
        (Join-Path $env:USERPROFILE '.codex\.sandbox-bin\codex.exe'),
        (Join-Path $env:USERPROFILE '.codex\plugins\.plugin-appserver\codex.exe')
    ) }
    $codex = @($codexCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($codex.Count -ne 1) {
        $script:AnalysisSkipReason = 'Die lokale Codex-CLI wurde nicht gefunden.'
        return New-FallbackAnalysis -Reason $script:AnalysisSkipReason
    }

    $prompt = Get-Content -Raw $promptPath
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($attempt in 1..$MaximumAnalysisAttempts) {
        $attemptRecord = $null
        $analysisPath = Join-Path $runtimeRoot "daily-log-review-analysis-attempt-$attempt.json"
        $stdoutPath = Join-Path $runtimeRoot "codex-output-attempt-$attempt.txt"
        try {
            Remove-Item -LiteralPath $analysisPath, $stdoutPath -Force -ErrorAction SilentlyContinue
            $arguments = @(
                'exec',
                '--ignore-user-config',
                '--skip-git-repo-check',
                '--ephemeral',
                '-c', 'approval_policy="never"',
                '-s', 'read-only',
                '-C', $runtimeRoot,
                '--output-schema', $schemaPath,
                '-o', $analysisPath,
                '--color', 'never',
                $prompt
            )
            & $codex[0] @arguments *> $stdoutPath
            $exitCode = $LASTEXITCODE
            $attemptRecord = [ordered]@{
                attempt = $attempt
                exit_code = $exitCode
                succeeded = $false
                error = $null
            }
            if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $analysisPath -PathType Leaf)) {
                throw "Codex-Auswertung Exitcode $exitCode; Ergebnisdatei vorhanden=$([bool](Test-Path -LiteralPath $analysisPath -PathType Leaf))."
            }
            $parsed = Get-Content -Raw -LiteralPath $analysisPath | ConvertFrom-Json -ErrorAction Stop
            foreach ($requiredProperty in @('overall_status', 'executive_summary', 'systems', 'findings', 'watch_items', 'notable_events', 'coverage_gaps')) {
                if ($null -eq $parsed.PSObject.Properties[$requiredProperty]) {
                    throw "Pflichtfeld '$requiredProperty' fehlt in der Analyse."
                }
            }
            foreach ($finding in @($parsed.findings)) {
                $finding.repair_requires_confirmation = $true
            }
            $attemptRecord.succeeded = $true
            $script:AnalysisAttempts.Add([pscustomobject]$attemptRecord)
            $script:AnalysisStatus = 'succeeded'
            if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
                $safeOutput = Protect-LogText (Get-Content -Raw -LiteralPath $stdoutPath)
                Set-Content -Encoding utf8NoBOM -LiteralPath $stdoutPath -Value $safeOutput
            }
            return Protect-Object $parsed
        }
        catch {
            $safeFailure = Protect-LogText $_.Exception.Message
            $failures.Add("Versuch ${attempt}: $safeFailure")
            if ($null -eq $attemptRecord) {
                $attemptRecord = [ordered]@{ attempt = $attempt; exit_code = $null; succeeded = $false; error = $safeFailure }
            }
            else { $attemptRecord.error = $safeFailure }
            $script:AnalysisAttempts.Add([pscustomobject]$attemptRecord)
            if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
                $safeOutput = Protect-LogText (Get-Content -Raw -LiteralPath $stdoutPath)
                Set-Content -Encoding utf8NoBOM -LiteralPath $stdoutPath -Value $safeOutput
            }
        }
    }
    New-FallbackAnalysis -Reason ("Die intelligente Auswertung ist nach $MaximumAnalysisAttempts Versuch(en) fehlgeschlagen. " + ($failures -join ' '))
}

function Read-ControlPlaneStatusFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('quality', 'recovery')][string]$Kind,
        [Parameter(Mandatory)][ValidateRange(1, 8760)][int]$MaximumAgeHours,
        [DateTimeOffset]$ReferenceTime = [DateTimeOffset]::Now
    )

    $result = [ordered]@{
        kind = $Kind
        valid = $false
        success = $false
        stale = $false
        generated_at = $null
        age_hours = $null
        error = $null
        failure_reason = $null
        status = $null
    }
    try {
        $absolutePath = [IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw 'Statusdatei fehlt.'
        }
        $status = Get-Content -Raw -LiteralPath $absolutePath -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        if (-not $status.PSObject.Properties['schema_version'] -or [int]$status.schema_version -ne 1) {
            throw 'Statusdatei hat eine nicht unterstützte Schema-Version.'
        }
        if (-not $status.PSObject.Properties['generated_at'] -or
            -not $status.PSObject.Properties['success']) {
            throw 'Statusdatei enthält nicht alle Pflichtfelder.'
        }
        if ($status.success -isnot [bool]) {
            throw 'Statusdatei enthält keinen booleschen Erfolgswert.'
        }
        $generatedAt = [DateTimeOffset]::Parse(
            [string]$status.generated_at,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        $ageHours = ($ReferenceTime - $generatedAt).TotalHours
        if ($ageHours -lt -0.1) { throw 'Statusdatei liegt unzulässig in der Zukunft.' }
        if ($Kind -eq 'recovery' -and
            (-not $status.PSObject.Properties['restore_test_passed'])) {
            throw 'Recovery-Status enthält kein Restore-Testergebnis.'
        }
        if ($Kind -eq 'recovery' -and $status.restore_test_passed -isnot [bool]) {
            throw 'Recovery-Status enthält kein boolesches Restore-Testergebnis.'
        }
        $result.valid = $true
        $result.success = [bool]$status.success -and
            ($Kind -ne 'recovery' -or [bool]$status.restore_test_passed)
        $result.stale = $ageHours -gt $MaximumAgeHours
        $result.generated_at = $generatedAt.ToString('o')
        $result.age_hours = [Math]::Round($ageHours, 1)
        $result.failure_reason = if ($status.PSObject.Properties['failure_reason']) {
            Protect-LogText $status.failure_reason
        }
        else {
            $null
        }
        $result.status = $status
    }
    catch {
        $result.error = Protect-LogText $_.Exception.Message
    }
    [pscustomobject]$result
}

function Get-ControlPlaneStatusCoverageResult {
    param([Parameter(Mandatory)][object]$Status)

    $success = [bool]$Status.valid -and [bool]$Status.success -and -not [bool]$Status.stale
    $error = if (-not [bool]$Status.valid) {
        [string]$Status.error
    }
    elseif ([bool]$Status.stale) {
        'Statusdatei ist veraltet.'
    }
    elseif (-not [bool]$Status.success) {
        if ($Status.failure_reason) { [string]$Status.failure_reason } else { 'Die letzte Kontrolle meldete einen Fehler.' }
    }
    else {
        $null
    }
    [pscustomobject]@{ success = $success; error = $error }
}

function Test-ManagedJobEngineState {
    param(
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][object[]]$Jobs
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $ExpectedNames) {
        $matches = @($Jobs | Where-Object name -eq $name)
        if ($matches.Count -ne 1) {
            $messages.Add("Der verwaltete Job '$name' ist nicht genau einmal aktiv registriert.")
            continue
        }
        $job = $matches[0]
        $problems = [System.Collections.Generic.List[string]]::new()
        if (-not [bool]$job.enabled) { $problems.Add('deaktiviert') }
        if ([string]$job.preflight_status -ne 'passed') { $problems.Add("Preflight=$($job.preflight_status)") }
        if ([string]$job.last_status -in @('failed', 'abandoned')) { $problems.Add("letzter Lauf=$($job.last_status)") }
        if ($problems.Count -gt 0) {
            $messages.Add("Der verwaltete Job '$name' ist nicht betriebsbereit: $($problems -join ', ').")
        }
    }
    [pscustomobject]@{
        healthy = $messages.Count -eq 0
        messages = @($messages)
    }
}

function Get-LocalJobEngineState {
    $engineUri = [uri]'http://127.0.0.1:8770/'
    $session = $null
    $landing = Invoke-WebRequest -Uri $engineUri -SessionVariable session -UseBasicParsing -TimeoutSec 10
    if ($landing.StatusCode -ne 200) { throw 'Lokale Job Engine antwortete nicht erfolgreich.' }
    $state = Invoke-RestMethod -Uri ([uri]::new($engineUri, 'api/state')) -WebSession $session -Method Get -TimeoutSec 10
    if (-not $state.PSObject.Properties['jobs']) { throw 'Job-Engine-Status enthält keine Jobs.' }
    $state
}

function Invoke-ControlPlaneStatusCollection {
    $systemId = 'admin_workstation'
    $selectedEvents = 0
    $specifications = @(
        [pscustomobject]@{
            source = 'weekly-control-plane-quality'
            kind = 'quality'
            path = Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab\quality\latest.json'
            maximum_age_hours = 8 * 24
        },
        [pscustomobject]@{
            source = 'monthly-control-plane-recovery'
            kind = 'recovery'
            path = Join-Path $env:LOCALAPPDATA 'CodexAdmin\control-plane\status\latest.json'
            maximum_age_hours = 35 * 24
        }
    )

    foreach ($specification in $specifications) {
        $status = Read-ControlPlaneStatusFile -Path $specification.path -Kind $specification.kind `
            -MaximumAgeHours $specification.maximum_age_hours
        $sourceEvents = 0
        if (-not $status.valid) {
            Add-SyntheticEvent -SystemId $systemId -Source $specification.source -Severity high `
                -Message "Control-Plane-Status nicht auswertbar: $($status.error)"
            $sourceEvents++
        }
        else {
            if (-not $status.success) {
                $reason = if ($status.failure_reason) { " Ursache: $($status.failure_reason)" } else { '' }
                Add-SyntheticEvent -SystemId $systemId -Source $specification.source -Severity high `
                    -Timestamp $status.generated_at -Message "Die letzte $($specification.kind)-Kontrolle ist fehlgeschlagen.$reason"
                $sourceEvents++
            }
            if ($status.stale) {
                Add-SyntheticEvent -SystemId $systemId -Source $specification.source -Severity high `
                    -Timestamp $status.generated_at -Message (
                        'Der letzte {0}-Status ist {1:N1} Stunden alt und überschreitet die erlaubten {2} Stunden.' -f
                        $specification.kind, $status.age_hours, $specification.maximum_age_hours
                    )
                $sourceEvents++
            }
            if ($status.success -and -not $status.stale) {
                Add-SyntheticEvent -SystemId $systemId -Source $specification.source -Severity info `
                    -Timestamp $status.generated_at -Message "Die letzte $($specification.kind)-Kontrolle war erfolgreich und ist aktuell."
                $sourceEvents++
            }
        }
        $selectedEvents += $sourceEvents
        $coverageState = Get-ControlPlaneStatusCoverageResult -Status $status
        $script:Coverage.Add([pscustomobject]@{
            system_id = $systemId
            source = $specification.source
            success = [bool]$coverageState.success
            lines_read = if ($status.valid) { 1 } else { 0 }
            selected_events = $sourceEvents
            error = $coverageState.error
        })
    }

    $jobSource = 'local-job-engine-control-jobs'
    $jobEvents = 0
    try {
        $definitionSet = Get-Content -Raw -LiteralPath (Resolve-CodexAdminDataPath -RepositoryRoot $repoRoot -RelativePath 'config\job-definitions.json') | ConvertFrom-Json
        $expectedNames = @($definitionSet.jobs | ForEach-Object { [string]$_.name })
        $state = Get-LocalJobEngineState
        $jobHealth = Test-ManagedJobEngineState -ExpectedNames $expectedNames -Jobs @($state.jobs)
        foreach ($message in @($jobHealth.messages)) {
            Add-SyntheticEvent -SystemId $systemId -Source $jobSource -Severity high -Message $message
            $jobEvents++
        }
        if ($jobHealth.healthy) {
            Add-SyntheticEvent -SystemId $systemId -Source $jobSource -Severity info `
                -Message "Alle $($expectedNames.Count) verwalteten Homelab-Jobs sind aktiviert und haben einen bestandenen Preflight."
            $jobEvents++
        }
        $script:Coverage.Add([pscustomobject]@{
            system_id = $systemId
            source = $jobSource
            success = [bool]$jobHealth.healthy
            lines_read = @($state.jobs).Count
            selected_events = $jobEvents
            error = if ($jobHealth.healthy) { $null } else { 'Mindestens ein verwalteter Job ist nicht betriebsbereit.' }
        })
    }
    catch {
        $safeError = Protect-LogText $_.Exception.Message
        Add-SyntheticEvent -SystemId $systemId -Source $jobSource -Severity high `
            -Message "Status der lokalen Job Engine nicht auswertbar: $safeError"
        $jobEvents++
        $script:Coverage.Add([pscustomobject]@{
            system_id = $systemId
            source = $jobSource
            success = $false
            lines_read = 0
            selected_events = $jobEvents
            error = $safeError
        })
    }
}

function Get-FindingStatus {
    param([AllowNull()][string]$Severity)
    if ($Severity -in @('critical', 'high')) { return 'critical' }
    if ($Severity -in @('medium', 'low')) { return 'warning' }
    'unknown'
}

function Get-Sha256Prefix {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    ([Convert]::ToHexString($hash)).Substring(0, 16).ToLowerInvariant()
}

function Record-KnowledgeObservation {
    param([Parameter(Mandatory)][hashtable]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 8 -Compress
    $result = @($json | & $node $knowledgeCli record-observation 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Knowledge observation failed: $(Protect-LogText ($result -join ' '))"
    }
}

function Record-AnalysisKnowledge {
    param([Parameter(Mandatory)][object]$Analysis)

    $source = "scheduled_daily_log_review:$runId"
    $overallStatus = if ($Analysis.overall_status -in @('ok', 'warning', 'critical', 'unknown')) {
        [string]$Analysis.overall_status
    } else { 'unknown' }
    Record-KnowledgeObservation -Payload @{
        system_id = $null
        kind = 'daily_log_review'
        status = $overallStatus
        summary = (Protect-LogText $Analysis.executive_summary)
        details = "Run $runId; findings=$(@($Analysis.findings).Count); watch_items=$(@($Analysis.watch_items).Count); coverage_gaps=$(@($Analysis.coverage_gaps).Count); repairs=none."
        source = $source
        confidence = 1.0
        valid_for_hours = 48
        observed_at = $startedAt.ToString('o')
    }

    foreach ($system in @($Analysis.systems)) {
        if ([string]$system.system_id -notin @($reviewConfig.systems)) { continue }
        $status = if ($system.status -in @('ok', 'warning', 'critical', 'unknown')) { [string]$system.status } else { 'unknown' }
        $details = if (@($system.coverage_gaps).Count -gt 0) {
            'Coverage gaps: ' + (@($system.coverage_gaps | ForEach-Object { Protect-LogText $_ }) -join '; ')
        } else { 'All configured sources completed.' }
        Record-KnowledgeObservation -Payload @{
            system_id = [string]$system.system_id
            kind = 'daily_log_review_summary'
            status = $status
            summary = (Protect-LogText $system.summary)
            details = $details
            source = $source
            confidence = 0.95
            valid_for_hours = 48
            observed_at = $startedAt.ToString('o')
        }
    }

    foreach ($finding in @($Analysis.findings)) {
        $systemId = [string]$finding.system_id
        if ($systemId -notin @($reviewConfig.systems)) { continue }
        $fingerprint = Get-Sha256Prefix "$systemId|$($finding.category)|$($finding.title)"
        $details = @(
            "Trend: $(Protect-LogText $finding.trend)",
            "Promoted from watch: $([bool]$finding.promoted_from_watch)",
            "Significance: $(Protect-LogText $finding.significance_reason)",
            "Evidence: $(Protect-LogText $finding.evidence)",
            "Impact: $(Protect-LogText $finding.likely_impact)",
            "Proposed action: $(Protect-LogText $finding.recommended_action)",
            'Repair requires explicit user confirmation: true'
        ) -join "`n"
        Record-KnowledgeObservation -Payload @{
            system_id = $systemId
            kind = "daily_log_finding:$fingerprint"
            status = Get-FindingStatus ([string]$finding.severity)
            summary = "[$($finding.severity)] $(Protect-LogText $finding.title): $(Protect-LogText $finding.summary)"
            details = $details
            source = $source
            confidence = [Math]::Max(0, [Math]::Min(1, [double]$finding.confidence))
            valid_for_hours = 48
            observed_at = $startedAt.ToString('o')
        }
    }

    foreach ($watch in @($Analysis.watch_items)) {
        $systemId = [string]$watch.system_id
        if ($systemId -notin @($reviewConfig.systems)) { continue }
        $fingerprint = Get-Sha256Prefix "$systemId|$($watch.category)|$($watch.title)"
        $details = @(
            "Trend: $(Protect-LogText $watch.trend)",
            "Evidence: $(Protect-LogText $watch.evidence)",
            "Occurrences in current window: $([Math]::Max(1, [int]$watch.occurrences))",
            "Escalation condition: $(Protect-LogText $watch.escalation_condition)",
            'No remediation proposed while below the reporting threshold.'
        ) -join "`n"
        Record-KnowledgeObservation -Payload @{
            system_id = $systemId
            kind = "daily_log_watch:$fingerprint"
            status = 'warning'
            summary = "[watch] $(Protect-LogText $watch.title): $(Protect-LogText $watch.summary)"
            details = $details
            source = $source
            confidence = [Math]::Max(0, [Math]::Min(1, [double]$watch.confidence))
            valid_for_hours = $watchWindowDays * 24
            observed_at = $startedAt.ToString('o')
        }
    }
}

function ConvertTo-MarkdownCell {
    param([AllowNull()][object]$Value)
    ((Protect-LogText $Value) -replace '\|', '\|' -replace '[\r\n]+', ' ')
}

function Get-StatusDisplay {
    param([AllowNull()][string]$Status)
    switch ($Status) {
        'ok' { '🟢 Gesund' }
        'warning' { '🟡 Warnung' }
        'critical' { '🔴 Kritisch' }
        default { '⚪ Unbekannt' }
    }
}

function Get-SeverityDisplay {
    param([AllowNull()][string]$Severity)
    switch ($Severity) {
        'critical' { '🔴 Kritisch' }
        'high' { '🟠 Hoch' }
        'medium' { '🟡 Mittel' }
        'low' { '🔵 Niedrig' }
        default { '⚪ Unbekannt' }
    }
}

function Get-TrendDisplay {
    param([AllowNull()][string]$Trend)
    switch ($Trend) {
        'new' { 'Neu' }
        'recurring' { 'Wiederholt' }
        'persistent' { 'Anhaltend' }
        'worsening' { 'Zunehmend' }
        default { 'Nicht sicher bestimmbar' }
    }
}

function Convert-AnalysisToMarkdown {
    param([Parameter(Mandatory)][object]$Analysis)

    $builder = [Text.StringBuilder]::new()
    $findingCount = @($Analysis.findings).Count
    $watchCount = @($Analysis.watch_items).Count
    $coverageCount = @($script:Coverage).Count
    $coverageOkCount = @($script:Coverage | Where-Object success).Count
    $newWatchCount = @($Analysis.watch_items | Where-Object trend -eq 'new').Count
    $recurringWatchCount = @($Analysis.watch_items | Where-Object trend -in @('recurring', 'persistent')).Count
    $worseningWatchCount = @($Analysis.watch_items | Where-Object trend -eq 'worsening').Count
    $promotedCount = @($Analysis.findings | Where-Object promoted_from_watch).Count
    $watchTrend = if ($worseningWatchCount -gt 0) {
        'steigend'
    } elseif ($recurringWatchCount -gt 0) {
        'wiederkehrend'
    } elseif ($newWatchCount -gt 0) {
        'neu beziehungsweise noch unbestätigt'
    } else {
        'unauffällig'
    }

    $null = $builder.AppendLine("# Homelab-Tagesbericht · $($startedAt.ToString('dd.MM.yyyy'))")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("> **Gesamtstatus: $(Get-StatusDisplay ([string]$Analysis.overall_status))**  ")
    $null = $builder.AppendLine("> **$findingCount nennenswerte Findings · $watchCount interne Beobachtungspunkte · $coverageOkCount/$coverageCount Quellen verfügbar · 0 Reparaturen**")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Systemübersicht')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('| System | Status | Kurzbewertung |')
    $null = $builder.AppendLine('|---|---|---|')
    foreach ($system in @($Analysis.systems)) {
        $summary = Protect-LogText $system.summary
        if (@($system.coverage_gaps).Count -gt 0) {
            $summary = "$summary Abdeckungslücke: $(@($system.coverage_gaps) -join '; ')"
        }
        $null = $builder.AppendLine("| $(ConvertTo-MarkdownCell $system.system_id) | $(ConvertTo-MarkdownCell (Get-StatusDisplay ([string]$system.status))) | $(ConvertTo-MarkdownCell $summary) |")
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Kurzfazit')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine((Protect-LogText $Analysis.executive_summary))
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Handlungsbedarf')
    $null = $builder.AppendLine()
    if ($findingCount -eq 0) {
        $null = $builder.AppendLine('Keine nennenswerten oder aktuell handlungsrelevanten Fehler im ausgewerteten Zeitraum gefunden.')
    }
    else {
        $findingNumber = 0
        foreach ($finding in @($Analysis.findings)) {
            $findingNumber++
            $null = $builder.AppendLine("### $findingNumber. $(Get-SeverityDisplay ([string]$finding.severity)) · $(Protect-LogText $finding.title)")
            $null = $builder.AppendLine()
            $null = $builder.AppendLine('| | |')
            $null = $builder.AppendLine('|---|---|')
            $null = $builder.AppendLine("| **System** | $(ConvertTo-MarkdownCell $finding.system_id) |")
            $null = $builder.AppendLine("| **Trend** | $(ConvertTo-MarkdownCell (Get-TrendDisplay ([string]$finding.trend))) |")
            $null = $builder.AppendLine("| **Bewertung** | $(ConvertTo-MarkdownCell $finding.summary) |")
            $null = $builder.AppendLine("| **Beobachtet** | $($finding.occurrences)-mal; zuerst $(ConvertTo-MarkdownCell $finding.first_seen), zuletzt $(ConvertTo-MarkdownCell $finding.last_seen) |")
            $null = $builder.AppendLine("| **Beleg** | $(ConvertTo-MarkdownCell $finding.evidence) |")
            $null = $builder.AppendLine("| **Mögliche Auswirkung** | $(ConvertTo-MarkdownCell $finding.likely_impact) |")
            $null = $builder.AppendLine("| **Warum nennenswert?** | $(ConvertTo-MarkdownCell $finding.significance_reason) |")
            $null = $builder.AppendLine("| **Vorschlag** | $(ConvertTo-MarkdownCell $finding.recommended_action) |")
            $null = $builder.AppendLine()
            $null = $builder.AppendLine('**Maßnahmenstatus:** Wartet auf ausdrückliche Bestätigung – nichts verändert.')
            $null = $builder.AppendLine()
        }
    }
    $null = $builder.AppendLine('## Interne Beobachtung')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("**$watchCount geringfügige Anomalien** werden intern verfolgt. Sie beeinflussen den Gesamtstatus nicht und erscheinen erst nach Überschreiten der Meldeschwelle mit Einzelheiten im Bericht.")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- Trend: **$watchTrend**")
    $null = $builder.AppendLine("- Neu hinzugekommen: **$newWatchCount**")
    $null = $builder.AppendLine("- Wiederholt oder anhaltend: **$recurringWatchCount**")
    $null = $builder.AppendLine("- Zunehmend: **$worseningWatchCount**")
    $null = $builder.AppendLine("- Heute zu Findings hochgestuft: **$promotedCount**")
    $null = $builder.AppendLine("- Beobachtungszeitraum: **$watchWindowDays Tage**")
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Erfolgreich geprüft')
    $null = $builder.AppendLine()
    if (@($Analysis.notable_events).Count -eq 0) {
        $null = $builder.AppendLine('Keine zusätzlichen bestätigten Erfolgs- oder Gesundheitsereignisse hervorzuheben.')
    }
    else {
        foreach ($event in @($Analysis.notable_events)) {
            $null = $builder.AppendLine("- **$(Protect-LogText $event.system_id) – $(Protect-LogText $event.title):** $(Protect-LogText $event.summary)")
        }
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Abdeckung')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('| System | Quelle | Ergebnis | Gelesene Zeilen | Ausgewählte Ereignisse |')
    $null = $builder.AppendLine('|---|---|---|---:|---:|')
    foreach ($row in $script:Coverage) {
        $result = if ($row.success) { 'ok' } else { "Fehler: $($row.error)" }
        $null = $builder.AppendLine("| $(ConvertTo-MarkdownCell $row.system_id) | $(ConvertTo-MarkdownCell $row.source) | $(ConvertTo-MarkdownCell $result) | $($row.lines_read) | $($row.selected_events) |")
    }
    if (@($Analysis.coverage_gaps).Count -gt 0) {
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('Abdeckungslücken:')
        foreach ($gap in @($Analysis.coverage_gaps)) {
            $null = $builder.AppendLine("- $(Protect-LogText $gap)")
        }
    }
    $null = $builder.AppendLine()
    $null = $builder.AppendLine('## Laufdetails')
    $null = $builder.AppendLine()
    $null = $builder.AppendLine("- Zeitraum: $($since.ToString('dd.MM.yyyy HH:mm')) bis $($startedAt.ToString('dd.MM.yyyy HH:mm')) Europe/Berlin")
    $null = $builder.AppendLine('- Modus: ausschließlich lesend')
    $null = $builder.AppendLine('- Reparaturen oder Konfigurationsänderungen: **keine**')
    $null = $builder.AppendLine('- Rohlogs gespeichert: **nein**')
    $null = $builder.AppendLine('- Geheimnisse: vor Persistierung entfernt')
    $null = $builder.AppendLine(('- Run-ID: `{0}`' -f $runId))
    $builder.ToString()
}

function Write-AtomicUtf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $resolvedDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $Path))
    if (-not (Test-Path -LiteralPath $resolvedDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $resolvedDirectory -Force | Out-Null
    }
    $target = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($target) -ne $resolvedDirectory) {
        throw 'Atomic publication target escaped its requested directory.'
    }
    $temporary = Join-Path $resolvedDirectory ('.{0}.{1}.{2}.tmp' -f [IO.Path]::GetFileName($target), $PID, [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        $temporaryInfo = Get-Item -LiteralPath $temporary
        if ($temporaryInfo.Length -le 0) { throw 'Atomic publication produced an empty artifact.' }
        [IO.File]::Move($temporary, $target, $true)
        $targetInfo = Get-Item -LiteralPath $target
        $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        [pscustomobject]@{
            path = $target
            relative_path = [IO.Path]::GetRelativePath($reportRoot, $target)
            bytes = $targetInfo.Length
            sha256 = $hash
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Test-RequiredCollectorCoverage {
    $requiredSystems = @($reviewConfig.collectors | Where-Object { $_.enabled -and $_.required } |
        ForEach-Object { [string]$_.system_id } | Sort-Object -Unique)
    $missingOrFailed = @($requiredSystems | Where-Object {
        $systemId = $_
        $rows = @($script:Coverage | Where-Object system_id -eq $systemId)
        $rows.Count -eq 0 -or @($rows | Where-Object { -not $_.success }).Count -gt 0
    })
    $missingOrFailed.Count -eq 0
}

function Write-Reports {
    param(
        [Parameter(Mandatory)][object]$Analysis,
        [bool]$KnowledgeRecorded,
        [bool]$RequiredCoverageOk
    )

    $publicationStage = [pscustomobject][ordered]@{
        name = 'publication'
        status = 'running'
        started_at = (Get-Date).ToString('o')
        completed_at = $null
        error = $null
    }
    $script:Stages.Add($publicationStage)
    $latestMarkdown = $null
    $latestHtml = $null
    $latestManifestPath = $null
    $latestManifestChecksumPath = $null
    $hadLatestMarkdown = $false
    $hadLatestHtml = $false
    $hadLatestManifest = $false
    $hadLatestManifestChecksum = $false
    $previousLatestMarkdown = $null
    $previousLatestHtml = $null
    $previousLatestManifest = $null
    $previousLatestManifestChecksum = $null
    $latestPublicationStarted = $false
    try {
        if (-not $KnowledgeRecorded) {
            $Analysis.coverage_gaps = @($Analysis.coverage_gaps) + 'Die Auswertung konnte nicht in der internen Wissensdatenbank protokolliert werden.'
        }
        $markdown = Convert-AnalysisToMarkdown $Analysis
        if ($markdown -notmatch [regex]::Escape($runId) -or $markdown -notmatch '^# Homelab-Tagesbericht') {
            throw 'Der Markdown-Bericht hat die Publikationsvalidierung nicht bestanden.'
        }
        $datedMarkdown = Join-Path $reportRoot "$runId.md"
        $datedHtml = Join-Path $reportRoot "$runId.html"
        $latestMarkdown = Join-Path $reportRoot 'latest.md'
        $latestHtml = Join-Path $reportRoot 'latest.html'
        $manifestPath = Join-Path $reportRoot "$runId.manifest.json"
        $latestManifestPath = Join-Path $reportRoot 'latest.manifest.json'
        $manifestChecksumPath = Join-Path $reportRoot "$runId.manifest.sha256"
        $latestManifestChecksumPath = Join-Path $reportRoot 'latest.manifest.sha256'
        $encoded = [Net.WebUtility]::HtmlEncode($markdown)
        $html = @"
<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Homelab-Tagesreport $runId</title>
<style>body{margin:0;background:#0b1220;color:#e5edf7;font:15px/1.55 ui-monospace,Consolas,monospace}main{max-width:1100px;margin:auto;padding:32px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#111b2e;border:1px solid #263654;border-radius:12px;padding:24px;box-shadow:0 10px 35px #0005}a{color:#76b7ff}</style>
</head><body><main><pre>$encoded</pre></main></body></html>
"@
        $datedMarkdownArtifact = Write-AtomicUtf8File -Path $datedMarkdown -Content $markdown
        $datedHtmlArtifact = Write-AtomicUtf8File -Path $datedHtml -Content $html
        $hadLatestMarkdown = Test-Path -LiteralPath $latestMarkdown -PathType Leaf
        $hadLatestHtml = Test-Path -LiteralPath $latestHtml -PathType Leaf
        $hadLatestManifest = Test-Path -LiteralPath $latestManifestPath -PathType Leaf
        $hadLatestManifestChecksum = Test-Path -LiteralPath $latestManifestChecksumPath -PathType Leaf
        $previousLatestMarkdown = if ($hadLatestMarkdown) { Get-Content -Raw -LiteralPath $latestMarkdown } else { $null }
        $previousLatestHtml = if ($hadLatestHtml) { Get-Content -Raw -LiteralPath $latestHtml } else { $null }
        $previousLatestManifest = if ($hadLatestManifest) { Get-Content -Raw -LiteralPath $latestManifestPath } else { $null }
        $previousLatestManifestChecksum = if ($hadLatestManifestChecksum) { Get-Content -Raw -LiteralPath $latestManifestChecksumPath } else { $null }
        $latestPublicationStarted = $true
        $latestMarkdownArtifact = Write-AtomicUtf8File -Path $latestMarkdown -Content $markdown
        $latestHtmlArtifact = Write-AtomicUtf8File -Path $latestHtml -Content $html

        $publicationCompletedAt = (Get-Date).ToString('o')
        $manifestStages = @($script:Stages | ForEach-Object {
            [ordered]@{
                name = [string]$_.name
                status = if ($_.name -eq 'publication') { 'succeeded' } else { [string]$_.status }
                started_at = [string]$_.started_at
                completed_at = if ($_.name -eq 'publication') { $publicationCompletedAt } else { [string]$_.completed_at }
                error = if ($_.name -eq 'publication') { $null } else { $_.error }
            }
        })
        $manifest = [ordered]@{
            schema_version = 1
            run_id = $runId
            generated_at = $startedAt.ToString('o')
            completed_at = $publicationCompletedAt
            publication_status = 'succeeded'
            analysis_status = $script:AnalysisStatus
            analysis_skip_reason = $script:AnalysisSkipReason
            analysis_attempts = @($script:AnalysisAttempts)
            stages = $manifestStages
            coverage = [ordered]@{
                total = @($script:Coverage).Count
                succeeded = @($script:Coverage | Where-Object success).Count
                failed = @($script:Coverage | Where-Object { -not $_.success }).Count
                required_ok = $RequiredCoverageOk
            }
            required_coverage_ok = $RequiredCoverageOk
            knowledge_recorded = $KnowledgeRecorded
            manifest_checksum = 'external_sha256'
            artifacts = @(@($datedMarkdownArtifact, $datedHtmlArtifact, $latestMarkdownArtifact, $latestHtmlArtifact) | ForEach-Object {
                [ordered]@{
                    relative_path = $_.relative_path
                    bytes = $_.bytes
                    sha256 = $_.sha256
                }
            })
        }
        $manifestJson = $manifest | ConvertTo-Json -Depth 10
        $manifestArtifact = Write-AtomicUtf8File -Path $manifestPath -Content $manifestJson
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestChecksumArtifact = Write-AtomicUtf8File -Path $manifestChecksumPath -Content ($manifestHash + "`n")
        $latestManifestArtifact = Write-AtomicUtf8File -Path $latestManifestPath -Content $manifestJson
        $latestManifestHash = (Get-FileHash -LiteralPath $latestManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($latestManifestHash -ne $manifestHash) { throw 'Dated and latest report manifests differ.' }
        $latestManifestChecksumArtifact = Write-AtomicUtf8File -Path $latestManifestChecksumPath -Content ($latestManifestHash + "`n")
        $publicationStage.status = 'succeeded'
        $publicationStage.completed_at = $publicationCompletedAt
        [pscustomobject]@{
            Markdown = $datedMarkdown
            Html = $datedHtml
            LatestMarkdown = $latestMarkdown
            LatestHtml = $latestHtml
            Manifest = $manifestArtifact.path
            LatestManifest = $latestManifestArtifact.path
            ManifestChecksum = $manifestChecksumArtifact.path
            LatestManifestChecksum = $latestManifestChecksumArtifact.path
        }
    }
    catch {
        if ($latestPublicationStarted) {
            if ($hadLatestMarkdown) { Write-AtomicUtf8File -Path $latestMarkdown -Content $previousLatestMarkdown | Out-Null }
            elseif ($latestMarkdown -and (Test-Path -LiteralPath $latestMarkdown -PathType Leaf)) { Remove-Item -LiteralPath $latestMarkdown -Force }
            if ($hadLatestHtml) { Write-AtomicUtf8File -Path $latestHtml -Content $previousLatestHtml | Out-Null }
            elseif ($latestHtml -and (Test-Path -LiteralPath $latestHtml -PathType Leaf)) { Remove-Item -LiteralPath $latestHtml -Force }
            if ($hadLatestManifest) { Write-AtomicUtf8File -Path $latestManifestPath -Content $previousLatestManifest | Out-Null }
            elseif ($latestManifestPath -and (Test-Path -LiteralPath $latestManifestPath -PathType Leaf)) { Remove-Item -LiteralPath $latestManifestPath -Force }
            if ($hadLatestManifestChecksum) { Write-AtomicUtf8File -Path $latestManifestChecksumPath -Content $previousLatestManifestChecksum | Out-Null }
            elseif ($latestManifestChecksumPath -and (Test-Path -LiteralPath $latestManifestChecksumPath -PathType Leaf)) { Remove-Item -LiteralPath $latestManifestChecksumPath -Force }
        }
        $publicationStage.status = 'failed'
        $publicationStage.completed_at = (Get-Date).ToString('o')
        $publicationStage.error = Protect-LogText $_.Exception.Message
        throw
    }
}

function Assert-CollectorRegistry {
    param(
        [Parameter(Mandatory)][object[]]$Collectors,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedCollectors
    )

    if ($Collectors.Count -eq 0) { throw 'Collector registry must contain at least one entry.' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($collector in $Collectors) {
        $collectorId = [string]$collector.id
        $systemId = [string]$collector.system_id
        $functionName = [string]$collector.function
        if ($collectorId -notmatch '^[a-z0-9][a-z0-9-]{0,79}$') { throw "Invalid collector id: $collectorId" }
        if (-not $ids.Add($collectorId)) { throw "Duplicate collector id: $collectorId" }
        if ([string]::IsNullOrWhiteSpace($systemId)) { throw "Collector $collectorId has no system_id." }
        if (-not $ApprovedCollectors.Contains($functionName)) { throw "Collector $collectorId is not in the approved adapter registry." }
        $pair = "$systemId|$functionName"
        if (-not $pairs.Add($pair)) { throw "Duplicate system/function collector mapping: $pair" }
        if ([bool]$collector.enabled -and -not [bool]$collector.read_only) { throw "Enabled collector $collectorId is not explicitly read-only." }
        $timeout = [int]$collector.timeout_seconds
        if ($timeout -lt 5 -or $timeout -gt 3600) { throw "Collector $collectorId has an invalid timeout_seconds value." }
        $adapterVersion = [int]$collector.adapter_version
        if ($adapterVersion -lt 1 -or $adapterVersion -gt 1000) { throw "Collector $collectorId has an invalid adapter_version." }
    }

    $enabledSystems = @($Collectors | Where-Object enabled | ForEach-Object { [string]$_.system_id } | Sort-Object -Unique)
    $declaredSystems = @($reviewConfig.systems | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    if (($enabledSystems -join '|') -ne ($declaredSystems -join '|')) {
        throw 'The declared daily-review systems do not exactly match the enabled collector registry.'
    }
}

function Invoke-IsolatedCollector {
    param(
        [Parameter(Mandatory)][object]$Collector,
        [string]$ScriptPath = $dailyReviewScriptPath
    )

    $functionName = [string]$Collector.function
    $timeoutSeconds = [int]$Collector.timeout_seconds
    $job = Start-Job -ScriptBlock {
        param($ScriptPath, $CollectorFunction, $Lookback, $RuntimePath, $ReportPath)
        try {
            . $ScriptPath -LibraryOnly -LookbackHours $Lookback -RuntimeDirectory $RuntimePath -ReportDirectory $ReportPath
            & $CollectorFunction | Out-Null
            [pscustomobject]@{
                payload_type = 'homelab_daily_collector_v1'
                success = $true
                events = @($script:Events)
                coverage = @($script:Coverage)
                error = $null
            }
        }
        catch {
            $safeError = if (Get-Command Protect-LogText -CommandType Function -ErrorAction SilentlyContinue) {
                Protect-LogText $_.Exception.Message
            }
            else { 'Collector failed before its sanitization helper was available.' }
            [pscustomobject]@{
                payload_type = 'homelab_daily_collector_v1'
                success = $false
                events = @()
                coverage = @()
                error = $safeError
            }
        }
    } -ArgumentList ([IO.Path]::GetFullPath($ScriptPath)), $functionName, $LookbackHours, $runtimeRoot, $reportRoot

    try {
        $completed = Wait-Job -Job $job -Timeout $timeoutSeconds
        if ($null -eq $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "Collector exceeded its configured timeout of $timeoutSeconds seconds."
        }
        $received = @(Receive-Job -Job $job -ErrorAction Stop)
        $payload = @($received | Where-Object { $_.payload_type -eq 'homelab_daily_collector_v1' } | Select-Object -Last 1)
        if ($payload.Count -ne 1) {
            $reason = if ($job.JobStateInfo.Reason) { Protect-LogText $job.JobStateInfo.Reason.Message } else { 'No structured collector result was returned.' }
            throw $reason
        }
        if (-not [bool]$payload[0].success) { throw (Protect-LogText $payload[0].error) }
        foreach ($event in @($payload[0].events)) { $script:Events.Add($event) }
        foreach ($row in @($payload[0].coverage)) { $script:Coverage.Add($row) }
    }
    finally {
        if ($job.State -in @('Running', 'NotStarted', 'Stopping')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

if ($LibraryOnly) { return }

try {
    $collectorMap = [ordered]@{
        'Invoke-ProxmoxCollection' = $true
        'Invoke-HomeAssistantCollection' = $true
        'Invoke-HomeAssistantAvailabilityCollection' = $true
        'Invoke-ReverseProxyCollection' = $true
        'Invoke-UniFiCollection' = $true
        'Invoke-WindowsCollection' = $true
        'Invoke-ControlPlaneStatusCollection' = $true
        'Invoke-PublicRelayCollection' = $true
        'Invoke-QnapCollection' = $true
        'Invoke-MinecraftCollection' = $true
    }
    Assert-CollectorRegistry -Collectors @($reviewConfig.collectors) -ApprovedCollectors $collectorMap
    foreach ($collector in @($reviewConfig.collectors | Where-Object enabled)) {
        $collectorId = [string]$collector.id
        $systemId = [string]$collector.system_id
        $functionName = [string]$collector.function
        if (-not [bool]$collector.read_only -or -not $collectorMap.Contains($functionName)) {
            Add-SourceLines -SystemId $systemId -Source "collector:$collectorId" -Lines @() `
                -Success $false -ErrorMessage 'Collector is not present in the approved read-only adapter registry.'
            continue
        }
        try {
            Invoke-TrackedStage -Name "collection:$collectorId" -Action { Invoke-IsolatedCollector -Collector $collector } | Out-Null
        }
        catch {
            Add-SourceLines -SystemId $systemId -Source "collector:$collectorId" -Lines @() `
                -Success $false -ErrorMessage $_.Exception.Message
        }
    }

    $analysis = Invoke-TrackedStage -Name 'analysis' -Action { Invoke-AiAnalysis }
    $analysis = Protect-Object $analysis
    $knowledgeRecorded = $false
    if (-not $SkipKnowledgeRecording) {
        try {
            Invoke-TrackedStage -Name 'knowledge' -Action { Record-AnalysisKnowledge $analysis } | Out-Null
            $knowledgeRecorded = $true
        }
        catch { $knowledgeRecorded = $false }
    }
    else {
        $script:Stages.Add([pscustomobject][ordered]@{
            name = 'knowledge'
            status = 'skipped'
            started_at = (Get-Date).ToString('o')
            completed_at = (Get-Date).ToString('o')
            error = $null
        })
    }
    $requiredCoverageOk = Test-RequiredCollectorCoverage
    $reports = Write-Reports -Analysis $analysis -KnowledgeRecorded $knowledgeRecorded -RequiredCoverageOk $requiredCoverageOk

    [pscustomobject]@{
        Success = $true
        SemanticSuccess = $script:AnalysisStatus -eq 'succeeded' -and $requiredCoverageOk
        RunId = $runId
        StartedAt = $startedAt.ToString('o')
        CompletedAt = (Get-Date).ToString('o')
        LookbackHours = $LookbackHours
        OverallStatus = $analysis.overall_status
        Findings = @($analysis.findings).Count
        CoverageGaps = @($analysis.coverage_gaps).Count
        AnalysisStatus = $script:AnalysisStatus
        AnalysisAttempts = @($script:AnalysisAttempts).Count
        RequiredCoverageOk = $requiredCoverageOk
        Stages = @($script:Stages)
        KnowledgeRecorded = $knowledgeRecorded
        Report = $reports.LatestMarkdown
        HtmlReport = $reports.LatestHtml
        Manifest = $reports.LatestManifest
        RepairsPerformed = 0
    }
}
finally {
    Set-Clipboard -Value ''
}
