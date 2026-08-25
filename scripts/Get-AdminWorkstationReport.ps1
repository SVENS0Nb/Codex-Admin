[CmdletBinding()]
param(
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
    $env:Path = "$userPath;$env:Path"
}
$toolNames = @(
    'git', 'pwsh', 'ssh', 'curl', 'scoop', 'python', 'node', 'npm',
    'jq', 'yq', 'gh', 'tofu', 'terraform', 'kubectl', 'helm', 'nmap'
)

$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$network = @(Get-NetIPConfiguration | Where-Object IPv4Address | ForEach-Object {
    [pscustomobject]@{
        interface = $_.InterfaceAlias
        ipv4 = @($_.IPv4Address.IPAddress)
        prefix_length = @($_.IPv4Address.PrefixLength)
        gateway = @($_.IPv4DefaultGateway.NextHop)
        dns = @($_.DNSServer.ServerAddresses)
    }
})
$tools = @($toolNames | ForEach-Object {
    $command = Get-Command $_ -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject]@{
        name = $_
        available = [bool]$command
        path = if ($command) { $command.Source } else { $null }
    }
})
$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$chrome = $chromePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
$null = & "$env:SystemRoot\System32\wsl.exe" --status 2>&1
$wslInstalled = $LASTEXITCODE -eq 0

$report = [pscustomobject]@{
    generated_at = (Get-Date).ToString('o')
    computer_name = $env:COMPUTERNAME
    user_name = $env:USERNAME
    windows = $os.Caption
    windows_version = $os.Version
    windows_build = $os.BuildNumber
    ram_gb = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
    logical_processors = $computer.NumberOfLogicalProcessors
    network = $network
    chrome = if ($chrome) { (Get-Item -LiteralPath $chrome).VersionInfo.ProductVersion } else { $null }
    wsl_installed = $wslInstalled
    tools = $tools
    repository = (Resolve-Path "$PSScriptRoot\.." -ErrorAction SilentlyContinue).Path
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 6
} else {
    $report
}
