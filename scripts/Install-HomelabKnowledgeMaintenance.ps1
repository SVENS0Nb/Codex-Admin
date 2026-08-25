[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'CodexAdmin - Homelab Knowledge Maintenance'
$maintenanceScript = (Resolve-Path (Join-Path $PSScriptRoot 'Update-HomelabKnowledge.ps1')).Path
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$maintenanceScript`""

$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User $identity
    New-ScheduledTaskTrigger -Daily -At '03:17'
)
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

$task = New-ScheduledTask -Action $action -Trigger $triggers -Principal $principal -Settings $settings
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

[pscustomobject]@{
    Success = $true
    TaskName = $taskName
    User = $identity
    DailyAt = '03:17'
    AtLogOn = $true
    RequiresUserLogon = $true
}
