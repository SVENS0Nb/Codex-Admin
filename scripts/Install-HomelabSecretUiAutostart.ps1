[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$taskName = 'CodexAdmin - Homelab Secret UI'
$runnerPath = (Resolve-Path (Join-Path $PSScriptRoot 'Start-HomelabSecretUiService.ps1')).Path
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "{0}"' -f $runnerPath

$action = New-ScheduledTaskAction -Execute $pwshPath -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settingsParameters = @{
    Hidden = $true
    StartWhenAvailable = $true
    RestartCount = 999
    RestartInterval = New-TimeSpan -Minutes 1
    ExecutionTimeLimit = [TimeSpan]::Zero
    MultipleInstances = 'IgnoreNew'
    AllowStartIfOnBatteries = $true
    DontStopIfGoingOnBatteries = $true
}
$settings = New-ScheduledTaskSettingsSet @settingsParameters

if (-not $PSCmdlet.ShouldProcess($taskName, 'Register per-user logon task')) {
    return
}

$registerParameters = @{
    TaskName = $taskName
    Action = $action
    Trigger = $trigger
    Principal = $principal
    Settings = $settings
    Description = 'Runs the loopback-only Homelab Secret UI for the signed-in Windows user.'
    Force = $true
}
Register-ScheduledTask @registerParameters | Out-Null

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $taskName
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
[pscustomobject]@{
    TaskName = $task.TaskName
    State = [string]$task.State
    User = $userId
    Trigger = 'AtLogOn'
}
