[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [DateTimeOffset]$PreviousBootTime,

    [string]$ResultPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.runtime\post-reboot-admin-verification.json'),

    [string]$TaskName = 'CodexAdmin - Post-Reboot Verification',

    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
$resultDirectory = Split-Path $ResultPath -Parent
if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
}

$bootTime = [DateTimeOffset](Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$expectedIdentity = "$env:COMPUTERNAME\Admin"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
$jobEngineHealthy = $false
$secretUiHealthy = $false
$codexRunning = $false
$codexTaskCompleted = $false

do {
    try {
        $jobEngineHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:8770/healthz' -TimeoutSec 3
        $jobEngineHealthy = [bool]$jobEngineHealth.ok
    }
    catch {
        $jobEngineHealthy = $false
    }

    try {
        $secretUiHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:8765/healthz' -TimeoutSec 3
        $secretUiHealthy = [bool]$secretUiHealth.ok
    }
    catch {
        $secretUiHealthy = $false
    }

    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($package) {
        $codexRunning = [bool](Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $_.Path -and $_.Path.StartsWith($package.InstallLocation, [StringComparison]::OrdinalIgnoreCase)
                }
                catch {
                    $false
                }
            } |
            Select-Object -First 1)
    }

    try {
        $codexTaskInfo = Get-ScheduledTaskInfo -TaskName 'CodexAdmin - Codex Desktop Autostart' -ErrorAction Stop
        $codexTaskCompleted = $codexTaskInfo.LastRunTime -ge $bootTime.LocalDateTime -and
            $codexTaskInfo.LastTaskResult -eq 0
    }
    catch {
        $codexTaskCompleted = $false
    }

    if (-not ($jobEngineHealthy -and $secretUiHealthy -and $codexRunning -and $codexTaskCompleted)) {
        Start-Sleep -Seconds 3
    }
} while ([DateTimeOffset]::Now -lt $deadline -and
    -not ($jobEngineHealthy -and $secretUiHealthy -and $codexRunning -and $codexTaskCompleted))

$winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$policyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$winlogon = Get-ItemProperty -Path $winlogonPath
$policy = Get-ItemProperty -Path $policyPath
$plaintextPasswordAbsent = $null -eq $winlogon.PSObject.Properties['DefaultPassword']
$logonBannerAbsent = $null -eq $policy.PSObject.Properties['LegalNoticeCaption'] -and
    $null -eq $policy.PSObject.Properties['LegalNoticeText']
$autoLogonCountAbsent = $null -eq $winlogon.PSObject.Properties['AutoLogonCount']
$autoLogonConfigured = [string]$winlogon.AutoAdminLogon -eq '1' -and
    [string]$winlogon.DefaultUserName -eq 'Admin' -and
    [string]$winlogon.DefaultDomainName -eq $env:COMPUTERNAME
$newBootObserved = $bootTime -gt $PreviousBootTime
$interactiveAdmin = $identity -eq $expectedIdentity

$success = $newBootObserved -and $interactiveAdmin -and $autoLogonConfigured -and
    $plaintextPasswordAbsent -and $logonBannerAbsent -and $autoLogonCountAbsent -and
    $jobEngineHealthy -and $secretUiHealthy -and $codexRunning -and $codexTaskCompleted

$result = [ordered]@{
    schema_version = 1
    checked_at = [DateTimeOffset]::Now.ToString('o')
    previous_boot_time = $PreviousBootTime.ToString('o')
    current_boot_time = $bootTime.ToString('o')
    new_boot_observed = $newBootObserved
    interactive_identity = $identity
    interactive_admin = $interactiveAdmin
    auto_logon_configured = $autoLogonConfigured
    plaintext_default_password_absent = $plaintextPasswordAbsent
    logon_banner_absent = $logonBannerAbsent
    auto_logon_count_absent = $autoLogonCountAbsent
    lsa_secret = 'Presence was verified elevated before reboot; this read-only post-logon check does not retrieve it.'
    job_engine_healthy = $jobEngineHealthy
    secret_ui_healthy = $secretUiHealthy
    codex_running = $codexRunning
    codex_autostart_task_completed = $codexTaskCompleted
    success = $success
}

$temporaryResult = "$ResultPath.tmp"
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryResult -Encoding utf8
Move-Item -LiteralPath $temporaryResult -Destination $ResultPath -Force

if ($success) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    }
    catch {
        # The result is authoritative; task cleanup can be completed interactively.
    }
}

$result
