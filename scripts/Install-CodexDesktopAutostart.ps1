[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$taskName = 'CodexAdmin - Codex Desktop Autostart'
$runnerPath = (Resolve-Path (Join-Path $PSScriptRoot 'Start-CodexDesktop.ps1')).Path
$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "{0}"' -f $runnerPath

$action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

if (-not $PSCmdlet.ShouldProcess($taskName, 'Register per-user Codex desktop autostart task')) {
    return
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Starts the installed OpenAI Codex desktop package when the configured interactive user signs in.' `
    -Force -ErrorAction Stop | Out-Null

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$triggerTypes = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
if ('MSFT_TaskLogonTrigger' -notin $triggerTypes -or $task.Principal.LogonType -ne 'Interactive') {
    throw 'Registered task did not retain the required interactive logon configuration.'
}

[pscustomobject]@{
    TaskName = $task.TaskName
    State = [string]$task.State
    User = $task.Principal.UserId
    Trigger = $triggerTypes -join ','
    Package = 'OpenAI.Codex'
}
