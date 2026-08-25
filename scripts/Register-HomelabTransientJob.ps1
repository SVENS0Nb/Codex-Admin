[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('ActiveTest', 'OneTime')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [string]$Description = '',

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CommandPath,

    [ValidateSet('powershell', 'executable')]
    [string]$CommandType = 'powershell',

    [string[]]$Arguments = @(),

    [string]$WorkingDirectory,

    [ValidateRange(5, 86400)]
    [int]$TimeoutSeconds = 900,

    [switch]$CaptureOutput,

    [ValidateSet('read_only', 'local_state_write', 'manual_only')]
    [string]$SafetyClassification = 'local_state_write',

    [string[]]$RequiredCredentialRef = @(),

    [hashtable[]]$RequiredEndpoint = @(),

    [string[]]$ExpectedArtifact = @(),

    [datetimeoffset]$ScheduledAt,

    [switch]$NoTaskWake,

    [ValidateSet('always', 'on_signal')]
    [string]$WakeCondition = 'always',

    [uri]$EngineUri = 'http://127.0.0.1:8770/'
)

$ErrorActionPreference = 'Stop'

if ($Mode -eq 'OneTime' -and -not $PSBoundParameters.ContainsKey('ScheduledAt')) {
    throw 'Für einen OneTime-Job ist -ScheduledAt erforderlich.'
}

$resolvedCommand = (Resolve-Path -LiteralPath $CommandPath).Path
if (-not $WorkingDirectory) {
    $WorkingDirectory = Split-Path -Parent $resolvedCommand
}
$resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path

$landingResponse = Invoke-WebRequest -Uri $EngineUri -SessionVariable session -UseBasicParsing
$csrfMatch = [regex]::Match($landingResponse.Content, '<meta\s+name="csrf-token"\s+content="([^"]+)"')
if (-not $csrfMatch.Success) {
    throw 'Die lokale Job-Engine lieferte kein CSRF-Token.'
}

$origin = $EngineUri.GetLeftPart([System.UriPartial]::Authority)
$headers = @{
    Origin = $origin
    'X-CSRF-Token' = $csrfMatch.Groups[1].Value
}
$payload = @{
    name = $Name
    description = $Description
    schedule = '0 * * * *'
    timezone = 'Europe/Berlin'
    command_type = $CommandType
    command_path = $resolvedCommand
    arguments = @($Arguments)
    working_directory = $resolvedWorkingDirectory
    timeout_seconds = $TimeoutSeconds
    capture_output = [bool]$CaptureOutput
    overlap_policy = 'skip'
    misfire_policy = 'run_once'
    safety_classification = $SafetyClassification
    required_credential_refs = @($RequiredCredentialRef)
    required_endpoints = @($RequiredEndpoint)
    expected_artifacts = @($ExpectedArtifact)
}

if ($Mode -eq 'OneTime') {
    if (-not $NoTaskWake) {
        $threadId = [string]$env:CODEX_THREAD_ID
        $parsedThreadId = [guid]::Empty
        if (-not [guid]::TryParse($threadId, [ref]$parsedThreadId)) {
            throw 'Der aktuelle Codex-Task konnte nicht sicher bestimmt werden. Verwende -NoTaskWake nur, wenn ausdrücklich keine Reaktivierung gewünscht ist.'
        }

        $permissionProfile = ([string]$env:CODEX_PERMISSION_PROFILE).Trim().TrimStart(':')
        if (-not $permissionProfile -and $env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE -eq 'Codex Desktop') {
            # Codex Desktop may omit CODEX_PERMISSION_PROFILE when this dedicated
            # admin VM is running with the disabled/unrestricted filesystem profile.
            $permissionProfile = 'danger-full-access'
        }
        $wakeSandboxMode = switch ($permissionProfile) {
            'danger-full-access' { 'danger-full-access' }
            'disabled' { 'danger-full-access' }
            'unrestricted' { 'danger-full-access' }
            'workspace-write' { 'workspace-write' }
            'read-only' { 'read-only' }
            default { throw 'Das aktuelle Codex-Berechtigungsprofil kann nicht sicher auf einen unbeaufsichtigten Reaktivierungslauf abgebildet werden.' }
        }

        $wakeWorkingDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $payload.wake_enabled = $true
        $payload.wake_thread_id = $parsedThreadId.ToString()
        $payload.wake_working_directory = $wakeWorkingDirectory
        $payload.wake_sandbox_mode = $wakeSandboxMode
        $payload.wake_approval_policy = 'never'
        $payload.wake_condition = $WakeCondition
    }
    $endpoint = [uri]::new($EngineUri, 'api/one-time-jobs')
    $payload.scheduled_at = $ScheduledAt.ToUniversalTime().ToString('o')
} else {
    $endpoint = [uri]::new($EngineUri, 'api/active-tests')
}

$response = Invoke-RestMethod -Method Post -Uri $endpoint -WebSession $session -Headers $headers `
    -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 6)

if ($Mode -eq 'ActiveTest') {
    [pscustomobject]@{
        Mode = $Mode
        JobId = $response.job.id
        RunId = $response.run.id
        Status = $response.run.status
    }
} else {
    [pscustomobject]@{
        Mode = $Mode
        JobId = $response.id
        ScheduledAt = $response.scheduled_at
        Status = 'scheduled'
        TaskWake = [bool]$response.wake_enabled
    }
}
