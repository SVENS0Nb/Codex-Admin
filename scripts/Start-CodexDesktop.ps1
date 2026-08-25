[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$jobEngineStarter = Join-Path $PSScriptRoot 'Ensure-HomelabJobEngine.ps1'
try {
    & $jobEngineStarter | Out-Null
}
catch {
    Write-Warning "Homelab Job Engine could not be started: $($_.Exception.Message)"
}

$package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $package) {
    throw 'The OpenAI.Codex Windows package is not installed for the current user.'
}

$existingProcess = Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue |
    Where-Object {
        try {
            $_.Path -and $_.Path.StartsWith($package.InstallLocation, [StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $false
        }
    } |
    Select-Object -First 1

if ($existingProcess) {
    [pscustomobject]@{
        State = 'AlreadyRunning'
        Package = $package.Name
        ProcessId = $existingProcess.Id
    }
    return
}

$startApp = Get-StartApps |
    Where-Object { $_.AppID -like "$($package.PackageFamilyName)!*" } |
    Select-Object -First 1

if (-not $startApp) {
    throw "No Start-menu application ID was found for $($package.PackageFamilyName)."
}

Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') `
    -ArgumentList "shell:AppsFolder\$($startApp.AppID)"

$startedProcess = $null
for ($attempt = 0; $attempt -lt 20 -and -not $startedProcess; $attempt++) {
    Start-Sleep -Milliseconds 500
    $startedProcess = Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $_.Path -and $_.Path.StartsWith($package.InstallLocation, [StringComparison]::OrdinalIgnoreCase)
            }
            catch {
                $false
            }
        } |
        Select-Object -First 1
}

if (-not $startedProcess) {
    throw 'The Codex desktop package was launched but no application process appeared within 10 seconds.'
}

[pscustomobject]@{
    State = 'Started'
    Package = $package.Name
    AppId = $startApp.AppID
    ProcessId = $startedProcess.Id
}
