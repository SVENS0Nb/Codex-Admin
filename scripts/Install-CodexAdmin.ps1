[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$SiteRoot,
    [switch]$SkipDependencyInstall,
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repository = (Resolve-Path -LiteralPath $RepositoryRoot).Path
Import-Module (Join-Path $repository 'scripts\CodexAdmin.Common.psm1') -Force

if ($SiteRoot) {
    $site = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($SiteRoot))
    $repositoryPrefix = $repository + [IO.Path]::DirectorySeparatorChar
    if ($site.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
        $site.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SiteRoot must remain outside the Git repository.'
    }
} else {
    $site = Get-CodexAdminSiteRoot -RepositoryRoot $repository
}

function Get-RequiredCommand {
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "Required command is unavailable: $Name" }
    $command.Source
}

$pwsh = Get-RequiredCommand 'pwsh.exe'
$git = Get-RequiredCommand 'git.exe'
$node = Get-RequiredCommand 'node.exe'
$npm = Get-RequiredCommand 'npm.cmd'
$python = Get-RequiredCommand 'python.exe'

$pwshMajor = [int](& $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.Major')
$nodeMajor = [int]((& $node --version).TrimStart('v').Split('.')[0])
$pythonVersion = (& $python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")').Trim()
$pythonParts = $pythonVersion.Split('.')
if ($pwshMajor -lt 7) { throw 'PowerShell 7 or newer is required.' }
if ($nodeMajor -ne 24) { throw "Node.js 24 is required; detected major version $nodeMajor." }
if ([int]$pythonParts[0] -lt 3 -or ([int]$pythonParts[0] -eq 3 -and [int]$pythonParts[1] -lt 11)) {
    throw "Python 3.11 or newer is required; detected $pythonVersion."
}

if (-not $SkipDependencyInstall) {
    foreach ($project in @(
        'mcp\homelab-admin',
        'apps\job-engine',
        'apps\secret-ui',
        'apps\unifi-security-log'
    )) {
        Push-Location (Join-Path $repository $project)
        try {
            & $npm ci --ignore-scripts --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) { throw "npm ci failed for $project" }
        }
        finally { Pop-Location }
    }
}

if (-not $SkipBuild) {
    Push-Location (Join-Path $repository 'mcp\homelab-admin')
    try {
        & $npm run build
        if ($LASTEXITCODE -ne 0) { throw 'Homelab MCP build failed.' }
    }
    finally { Pop-Location }
}

New-Item -ItemType Directory -Path $site -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($principal in @($identity, 'NT AUTHORITY\SYSTEM')) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $principal,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $site -AclObject $acl

$siteFiles = @(
    'inventory\services.json',
    'inventory\systems.json',
    'inventory\interfaces.json',
    'inventory\service-catalog.json',
    'inventory\access-profiles.json',
    'inventory\capabilities.json',
    'inventory\dependencies.json',
    'inventory\maintenance.json',
    'config\daily-log-review.json',
    'config\job-definitions.json'
)
$created = [Collections.Generic.List[string]]::new()
foreach ($relative in $siteFiles) {
    $source = Join-Path $repository $relative
    $target = Join-Path $site $relative
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (-not (Test-Path -LiteralPath $target)) {
        Copy-Item -LiteralPath $source -Destination $target
        $created.Add($relative.Replace('\', '/'))
    }
}

$previousSiteRoot = [Environment]::GetEnvironmentVariable('CODEX_ADMIN_SITE_ROOT', 'Process')
try {
    $env:CODEX_ADMIN_SITE_ROOT = $site
    $knowledgeCli = Join-Path $repository 'mcp\homelab-admin\build\cli.js'
    & $node $knowledgeCli init | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Knowledge database initialization failed.' }
}
finally {
    if ($null -eq $previousSiteRoot) {
        [Environment]::SetEnvironmentVariable('CODEX_ADMIN_SITE_ROOT', $null, 'Process')
    } else {
        $env:CODEX_ADMIN_SITE_ROOT = $previousSiteRoot
    }
}

$runtimeConfig = Join-Path $env:LOCALAPPDATA 'CodexAdmin\config'
New-Item -ItemType Directory -Path $runtimeConfig -Force | Out-Null
$stagedAgentRoot = Join-Path $runtimeConfig 'agent-assets'
$stagedSkillRoot = Join-Path $stagedAgentRoot 'skills\homelab-admin'
New-Item -ItemType Directory -Path $stagedSkillRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repository 'skills\homelab-admin\SKILL.md') -Destination (Join-Path $stagedSkillRoot 'SKILL.md') -Force
Copy-Item -LiteralPath (Join-Path $repository 'AGENTS.md') -Destination (Join-Path $stagedAgentRoot 'AGENTS.md') -Force
$entrypoint = (Join-Path $repository 'mcp\homelab-admin\build\index.js').Replace('\', '\\')
$fragment = @"
# Generated by Install-CodexAdmin.ps1. Contains no credential values.
[mcp_servers.homelab_admin]
command = "node"
args = ["$entrypoint"]
"@
$fragmentPath = Join-Path $runtimeConfig 'homelab-admin-mcp.toml'
[IO.File]::WriteAllText($fragmentPath, $fragment, [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    ok = $true
    repository_root = $repository
    site_root = $site
    site_files_created = @($created)
    knowledge_database = Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab\homelab-ops.sqlite3'
    mcp_fragment = $fragmentPath
    staged_agent_assets = $stagedAgentRoot
    versions = [ordered]@{
        powershell = $pwshMajor
        node = $nodeMajor
        python = $pythonVersion
        git = (& $git --version).Trim()
    }
    live_jobs_enabled = $false
    codex_configuration_modified = $false
}
