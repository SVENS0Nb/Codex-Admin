[CmdletBinding()]
param()

$result = [ordered]@{
    ok                 = $true
    kind               = 'codex_task_wake_self_test'
    completed_at       = (Get-Date).ToUniversalTime().ToString('o')
    job_id_present     = -not [string]::IsNullOrWhiteSpace($env:CODEX_JOB_ID)
    job_run_id_present = -not [string]::IsNullOrWhiteSpace($env:CODEX_JOB_RUN_ID)
}

$result | ConvertTo-Json -Compress
