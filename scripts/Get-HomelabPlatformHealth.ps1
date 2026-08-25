[CmdletBinding()]
param(
    [switch]$SkipLive,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$versionConfig = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'config\platform-versions.json') | ConvertFrom-Json
$checks = [Collections.Generic.List[object]]::new()

function Add-PlatformCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][string]$Detail,
        [ValidateSet('required', 'informational')][string]$Severity = 'required'
    )
    $checks.Add([pscustomobject]@{ name = $Name; ok = $Ok; severity = $Severity; detail = $Detail })
}

foreach ($component in @($versionConfig.components)) {
    $manifestPath = Join-Path $repositoryRoot ([string]$component.manifest)
    $actualVersion = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
            $actualVersion = if ($component.id -eq 'daily_log_review') { [string]$manifest.workflow_version } else { [string]$manifest.version }
        }
        catch {}
    }
    Add-PlatformCheck -Name "component_version:$($component.id)" `
        -Ok ($actualVersion -eq [string]$component.version) `
        -Detail "expected=$($component.version); actual=$(if($actualVersion){$actualVersion}else{'unavailable'})"
}

$nodeVersion = (& node.exe --version).TrimStart('v')
$npmVersion = (& npm.cmd --version).Trim()
$pythonVersion = (& python.exe -c 'import platform; print(platform.python_version())').Trim()
$paramikoVersion = (& python.exe -c 'import paramiko; print(paramiko.__version__)').Trim()
$pesterVersion = [string](Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version
Add-PlatformCheck -Name 'runtime:node-major' -Ok ([version]$nodeVersion -ge [version]'24.0.0' -and [version]$nodeVersion -lt [version]'25.0.0') -Detail "actual=$nodeVersion"
Add-PlatformCheck -Name 'runtime:npm' -Ok (-not [string]::IsNullOrWhiteSpace($npmVersion)) -Detail "actual=$npmVersion"
Add-PlatformCheck -Name 'runtime:powershell' -Ok ($PSVersionTable.PSVersion -ge [version]'7.4.0') -Detail "actual=$($PSVersionTable.PSVersion)"
Add-PlatformCheck -Name 'runtime:python' -Ok ([version]$pythonVersion -ge [version]'3.12.0' -and [version]$pythonVersion -lt [version]'3.15.0') -Detail "actual=$pythonVersion"
Add-PlatformCheck -Name 'runtime:paramiko' -Ok (-not [string]::IsNullOrWhiteSpace($paramikoVersion)) -Detail "actual=$paramikoVersion"
Add-PlatformCheck -Name 'runtime:pester' -Ok ([version]$pesterVersion -ge [version]'3.4.0') -Detail "actual=$pesterVersion"

$knowledgeCli = Join-Path $repositoryRoot 'mcp\homelab-admin\build\cli.js'
try {
    $knowledgeIntegrity = & node.exe $knowledgeCli integrity | ConvertFrom-Json
    $knowledgeStats = & node.exe $knowledgeCli stats | ConvertFrom-Json
    $expectedSchema = [int](@($versionConfig.components | Where-Object id -eq 'homelab_admin_mcp' | Select-Object -First 1).database_schema_version)
    Add-PlatformCheck -Name 'database:knowledge-integrity' `
        -Ok ([bool]$knowledgeIntegrity.ok -and [int]$knowledgeStats.schema_version -eq $expectedSchema) `
        -Detail "schema=$($knowledgeStats.schema_version); expected=$expectedSchema"
}
catch { Add-PlatformCheck -Name 'database:knowledge-integrity' -Ok $false -Detail 'integrity command failed' }

$jobDatabase = Join-Path $env:LOCALAPPDATA 'CodexAdmin\job-engine\jobs.sqlite3'
if (Test-Path -LiteralPath $jobDatabase -PathType Leaf) {
    try {
        $jobIntegrity = & node.exe (Join-Path $repositoryRoot 'apps\job-engine\backup.mjs') verify $jobDatabase | ConvertFrom-Json
        Add-PlatformCheck -Name 'database:job-engine-integrity' -Ok ([bool]$jobIntegrity.ok) -Detail "schema=$($jobIntegrity.user_version); jobs=$($jobIntegrity.counts.jobs); runs=$($jobIntegrity.counts.runs)"
    }
    catch { Add-PlatformCheck -Name 'database:job-engine-integrity' -Ok $false -Detail 'integrity command failed' }
}
else { Add-PlatformCheck -Name 'database:job-engine-integrity' -Ok $false -Detail 'database missing' }

try {
    $knowledgeWiring = & (Join-Path $repositoryRoot 'scripts\Test-HomelabKnowledge.ps1')
    Add-PlatformCheck -Name 'wiring:homelab-knowledge' -Ok ([bool]$knowledgeWiring.AllPassed) `
        -Detail "checks=$(@($knowledgeWiring.PSObject.Properties | Where-Object Name -ne 'AllPassed').Count)"
}
catch { Add-PlatformCheck -Name 'wiring:homelab-knowledge' -Ok $false -Detail 'wiring check failed' }

if (-not $SkipLive) {
    foreach ($endpoint in @(
        @{ name = 'service:job-engine'; uri = 'http://127.0.0.1:8770/healthz'; expected = 'homelab-job-engine' },
        @{ name = 'service:secret-ui'; uri = 'http://127.0.0.1:8765/healthz'; expected = 'homelab-secret-ui' }
    )) {
        try {
            $health = Invoke-RestMethod -Uri $endpoint.uri -TimeoutSec 3
            Add-PlatformCheck -Name $endpoint.name -Ok ([bool]$health.ok -and [string]$health.service -eq $endpoint.expected) `
                -Detail "version=$([string]$health.version)"
        }
        catch { Add-PlatformCheck -Name $endpoint.name -Ok $false -Detail 'loopback health endpoint unavailable' }
    }

    $reportRoot = Join-Path $env:LOCALAPPDATA 'CodexAdmin\homelab\reports'
    $manifestPath = Join-Path $reportRoot 'latest.manifest.json'
    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        $checksumPath = Join-Path $reportRoot 'latest.manifest.sha256'
        $expectedManifestHash = (Get-Content -Raw -LiteralPath $checksumPath).Trim()
        $payloadOk = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedManifestHash
        $artifactsOk = $true
        foreach ($artifact in @($manifest.artifacts)) {
            $relative = [string]$artifact.relative_path
            if ([IO.Path]::IsPathRooted($relative)) { $artifactsOk = $false; break }
            $artifactPath = [IO.Path]::GetFullPath((Join-Path $reportRoot $relative))
            if (-not $artifactPath.StartsWith($reportRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
                (Get-Item -LiteralPath $artifactPath).Length -ne [int64]$artifact.bytes -or
                (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$artifact.sha256) {
                $artifactsOk = $false
                break
            }
        }
        Add-PlatformCheck -Name 'report:latest-manifest' -Ok ($payloadOk -and $artifactsOk -and $manifest.publication_status -eq 'succeeded') `
            -Detail "payload_hash=$payloadOk; artifacts=$artifactsOk; publication=$($manifest.publication_status)"
    }
    catch { Add-PlatformCheck -Name 'report:latest-manifest' -Ok $false -Detail 'latest manifest unavailable or invalid' }

    foreach ($taskName in @(
        'CodexAdmin - Codex Desktop Autostart',
        'CodexAdmin - Homelab Knowledge Maintenance',
        'CodexAdmin - Homelab Secret UI'
    )) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Add-PlatformCheck -Name "scheduled_task:$taskName" -Ok ($null -ne $task) `
            -Detail $(if ($task) { "state=$($task.State)" } else { 'missing' })
    }
}

$requiredFailures = @($checks | Where-Object { $_.severity -eq 'required' -and -not $_.ok })
$result = [pscustomobject]@{
    generated_at = [DateTimeOffset]::Now.ToString('o')
    all_passed = $requiredFailures.Count -eq 0
    check_count = $checks.Count
    failed_count = $requiredFailures.Count
    live_checks_skipped = [bool]$SkipLive
    checks = @($checks)
}
if ($AsJson) { $result | ConvertTo-Json -Depth 8 } else { $result }
