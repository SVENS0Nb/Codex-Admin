[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$globalAgents = Join-Path $env:USERPROFILE '.codex\AGENTS.md'
$projectAgents = Join-Path $repositoryRoot 'AGENTS.md'
$skill = Join-Path $env:USERPROFILE '.codex\skills\homelab-admin\SKILL.md'
$config = Join-Path $env:USERPROFILE '.codex\config.toml'
$knowledgeRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab'
$databasePath = Join-Path $knowledgeRoot 'homelab-ops.sqlite3'
$backupRoot = Join-Path $knowledgeRoot 'backups'
$cli = Join-Path $repositoryRoot 'mcp\homelab-admin\build\cli.js'
$taskName = 'CodexAdmin - Homelab Knowledge Maintenance'
$dailyAutomationPath = Join-Path $env:USERPROFILE '.codex\automations\homelab-tagesreport-hier-zustellen\automation.toml'

$globalText = Get-Content -LiteralPath $globalAgents -Raw
$projectText = Get-Content -LiteralPath $projectAgents -Raw
$skillText = Get-Content -LiteralPath $skill -Raw
$configText = Get-Content -LiteralPath $config -Raw
$context = & node.exe $cli context full | ConvertFrom-Json
$integrity = & node.exe $cli integrity | ConvertFrom-Json
$rootAcl = Get-Acl -LiteralPath $knowledgeRoot
$allowedPrincipals = @(
    [Security.Principal.WindowsIdentity]::GetCurrent().Name,
    'NT AUTHORITY\SYSTEM'
)
$actualPrincipals = @($rootAcl.Access | ForEach-Object IdentityReference | ForEach-Object Value | Sort-Object -Unique)
$unexpectedPrincipals = @($actualPrincipals | Where-Object { $_ -notin $allowedPrincipals })
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName $taskName } else { $null }
$dailyAutomationText = if (Test-Path -LiteralPath $dailyAutomationPath -PathType Leaf) {
    Get-Content -LiteralPath $dailyAutomationPath -Raw
}
else {
    ''
}
$requiredDailyReadTools = @(
    'context_bootstrap',
    'knowledge_statistics',
    'knowledge_search',
    'incident_search',
    'system_context_get',
    'inventory_get',
    'admin_policy_get',
    'service_tcp_check'
)
$missingDailyReadTools = @($requiredDailyReadTools | Where-Object {
    $dailyAutomationText -notmatch [regex]::Escape($_)
})

$results = [ordered]@{
    GlobalAgentsBootstrapRule = $globalText -match 'context_bootstrap'
    ProjectAgentsBootstrapRule = $projectText -match 'context_bootstrap'
    ProjectAgentsDatabaseRules = $projectText -match 'Knowledge database'
    SkillBootstrapRule = $skillText -match 'context_bootstrap'
    McpConfigured = $configText -match '\[mcp_servers\.homelab_admin\]' -and $configText -match 'homelab-admin\\build\\index\.js'
    MemoriesEnabled = $configText -match 'generate_memories\s*=\s*true' -and $configText -match 'use_memories\s*=\s*true'
    DatabaseExists = Test-Path -LiteralPath $databasePath -PathType Leaf
    DatabaseIntegrity = [bool]$integrity.ok
    ContextRoleLoaded = -not [string]::IsNullOrWhiteSpace([string]$context.role)
    ContextSystemsLoaded = @($context.systems).Count -ge 34
    ContextServicesLoaded = @($context.service_catalog).Count -ge 58
    ContextAccessLoaded = @($context.access_profiles).Count -ge 8
    ContextCapabilitiesLoaded = @($context.verified_capabilities).Count -ge 6
    ProtectedKnowledgeDirectory = $rootAcl.AreAccessRulesProtected -and $unexpectedPrincipals.Count -eq 0
    BackupExists = @(Get-ChildItem -LiteralPath $backupRoot -Filter '*.sqlite3' -File -ErrorAction SilentlyContinue).Count -ge 1
    MaintenanceTaskInstalled = $null -ne $task
    MaintenanceTaskLastRunSucceeded = $null -ne $taskInfo -and $taskInfo.LastTaskResult -eq 0
    DailyAutomationInstalled = -not [string]::IsNullOrWhiteSpace($dailyAutomationText)
    DailyAutomationActive = $dailyAutomationText -match 'kind\s*=\s*"heartbeat"' -and
        $dailyAutomationText -match 'status\s*=\s*"ACTIVE"' -and
        $dailyAutomationText -match 'rrule\s*=\s*"FREQ=DAILY;BYHOUR=18;BYMINUTE=10"'
    DailyAutomationThreadBound = $dailyAutomationText -match 'target_thread_id\s*=\s*"[0-9a-fA-F-]{36}"'
    DailyAutomationUsesHomelabSkill = $dailyAutomationText -match '\$homelab-admin' -and
        $dailyAutomationText -match 'C:\\\\Users\\\\Admin\\\\Ops\\\\homelab-ops'
    DailyAutomationUsesSharedKnowledge = $dailyAutomationText -match 'homelab_admin' -and
        $dailyAutomationText -match 'homelab-ops\.sqlite3'
    DailyAutomationReadTools = $missingDailyReadTools.Count -eq 0
    DailyAutomationResultsAccessible = $dailyAutomationText -match 'alle benutzerrelevanten Ergebnisse vollständig' -and
        $dailyAutomationText -match 'CodexAdmin\\\\homelab\\\\reports'
    DailyAutomationReadOnlyBoundary = $dailyAutomationText -match 'gegenüber der Infrastruktur ausschließlich lesen' -and
        $dailyAutomationText -match 'Keine Reparatur' -and
        $dailyAutomationText -match 'bestätigungspflichtige Mutation'
}
$results.AllPassed = -not ($results.Values -contains $false)
[pscustomobject]$results
