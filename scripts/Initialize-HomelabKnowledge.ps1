[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mcpRoot = Join-Path $repositoryRoot 'mcp\homelab-admin'
$knowledgeRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab'
$databasePath = Join-Path $knowledgeRoot 'homelab-ops.sqlite3'
$backupRoot = Join-Path $knowledgeRoot 'backups'

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($principal in @($identity, 'NT AUTHORITY\SYSTEM')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $principal,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

Push-Location $mcpRoot
try {
    & npm.cmd run build | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Homelab MCP build failed.' }
    $initialization = & node.exe '.\build\cli.js' init | ConvertFrom-Json
    if (-not $initialization.ok) { throw 'Knowledge database initialization failed.' }
}
finally {
    Pop-Location
}

foreach ($directory in @($knowledgeRoot, $backupRoot)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $existingAcl = Get-Acl -LiteralPath $directory
    $allowed = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'NT AUTHORITY\SYSTEM'
    )
    $unexpected = @($existingAcl.Access | ForEach-Object IdentityReference | ForEach-Object Value | Where-Object { $_ -notin $allowed })
    if (-not $existingAcl.AreAccessRulesProtected -or $unexpected.Count -gt 0) {
        Set-PrivateDirectoryAcl -Path $directory
    }
}

if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
    throw 'Knowledge database file was not created.'
}

[pscustomobject]@{
    Success = $true
    DatabasePath = $databasePath
    SchemaVersion = $initialization.schema_version
    SystemCount = $initialization.counts.systems
    AccessProfileCount = $initialization.counts.access_profiles
    CapabilityCount = $initialization.counts.capabilities
    KnowledgeEntryCount = $initialization.counts.knowledge_entries
}
