[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
        $value = [guid]::Empty
        [guid]::TryParse($_, [ref]$value)
    })]
    [string]$RunId,

    [uri]$EngineUri = 'http://127.0.0.1:8770/'
)

$ErrorActionPreference = 'Stop'

$null = Invoke-WebRequest -Uri $EngineUri -SessionVariable session -UseBasicParsing
$endpoint = [uri]::new($EngineUri, "api/runs/$RunId")
$response = Invoke-RestMethod -Method Get -Uri $endpoint -WebSession $session

[pscustomobject]@{
    RunId = $response.run.id
    JobId = $response.run.job_id
    JobName = $response.job.name
    Trigger = $response.run.trigger_type
    Status = $response.run.status
    ScheduledFor = $response.run.scheduled_for
    StartedAt = $response.run.started_at
    FinishedAt = $response.run.finished_at
    ExitCode = $response.run.exit_code
    Error = $response.run.error
    Stdout = $response.run.stdout
    Stderr = $response.run.stderr
    WakeStatus = $response.run.wake_status
    WakeAttempts = $response.run.wake_attempts
    WakeError = $response.run.wake_error
}
