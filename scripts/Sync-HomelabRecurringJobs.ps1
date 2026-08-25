[CmdletBinding()]
param(
    [uri]$EngineUri = 'http://127.0.0.1:8770/',

    [string[]]$Name = @(),

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'CodexAdmin.Common.psm1') -Force
$definitionPath = Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'config\job-definitions.json'
$accessProfilePath = Resolve-CodexAdminDataPath -RepositoryRoot $repositoryRoot -RelativePath 'inventory\access-profiles.json'
$definitionSet = Get-Content -Raw -LiteralPath $definitionPath | ConvertFrom-Json
$accessProfileSet = Get-Content -Raw -LiteralPath $accessProfilePath | ConvertFrom-Json

if ([int]$definitionSet.schema_version -ne 2) { throw 'Unsupported Homelab job-definition schema.' }
$definitions = @($definitionSet.jobs)
if ($definitions.Count -eq 0) { throw 'No managed Homelab jobs are defined.' }
if (@($definitions.id | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw 'Managed job identifiers must be unique.' }
if (@($definitions.name | Group-Object | Where-Object Count -gt 1).Count -gt 0) { throw 'Managed job names must be unique.' }
if (@($Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    $unknown = @($Name | Where-Object { $_ -notin @($definitions.name) })
    if (@($unknown).Count -gt 0) { throw "Unknown managed job name(s): $($unknown -join ', ')" }
    $definitions = @($definitions | Where-Object { $_.name -in $Name })
}

$profiles = @{}
foreach ($profile in @($accessProfileSet.profiles)) { $profiles[[string]$profile.id] = $profile }

function Expand-ManagedPath {
    param(
        [Parameter(Mandatory)][string]$Value,
        [switch]$RepositoryRelative
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Value)
    if ($RepositoryRelative -and -not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $repositoryRoot $expanded
    }
    [IO.Path]::GetFullPath($expanded)
}

function Resolve-CanonicalExistingPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) { throw 'Canonical path target does not exist.' }
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    $relative = [IO.Path]::GetRelativePath($pathRoot, $fullPath)
    $current = $pathRoot
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_ -and $_ -ne '.' })) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force
        $resolvedLink = $item.ResolveLinkTarget($true)
        if ($resolvedLink) { $current = $resolvedLink.FullName }
    }
    [IO.Path]::GetFullPath($current)
}

function Test-PathWithinRepository {
    param([Parameter(Mandatory)][string]$Path)
    $root = (Resolve-CanonicalExistingPath -Path $repositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $candidate = Resolve-CanonicalExistingPath -Path $Path
    $relative = [IO.Path]::GetRelativePath($root, $candidate)
    $relative -eq '.' -or (
        -not [IO.Path]::IsPathRooted($relative) -and
        $relative -ne '..' -and
        -not $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)
    )
}

function Resolve-DependencyManifest {
    param(
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][string]$CommandPath
    )

    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($dependency in @($Definition.dependency_paths)) {
        $value = [string]$dependency
        if ($value -eq '@repository-files') {
            $relativeFiles = @(& git -C $repositoryRoot ls-files --cached --others --exclude-standard)
            if ($LASTEXITCODE -ne 0 -or $relativeFiles.Count -eq 0) {
                throw "Repository dependencies could not be enumerated for $($Definition.name)."
            }
            foreach ($relative in $relativeFiles) {
                $candidates.Add((Expand-ManagedPath -Value ([string]$relative) -RepositoryRelative))
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidates.Add((Expand-ManagedPath -Value $value -RepositoryRelative))
        }
    }
    $candidates.Add($CommandPath)

    $unique = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Managed dependency is missing for $($Definition.name): $([IO.Path]::GetFileName($candidate))"
        }
        if (-not (Test-PathWithinRepository -Path $candidate)) {
            throw "Managed dependency escapes the repository for $($Definition.name)."
        }
        $unique[$candidate] = $candidate
    }
    if ($unique.Count -gt 256) { throw "Managed dependency manifest is too large for $($Definition.name)." }

    @($unique.Values | Sort-Object | ForEach-Object {
        [ordered]@{
            path = $_
            sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
            role = if ([string]::Equals($_, $CommandPath, [StringComparison]::OrdinalIgnoreCase)) { 'command' } else { 'runtime_dependency' }
        }
    })
}

$resolvedDefinitions = foreach ($definition in $definitions) {
    $commandPath = Expand-ManagedPath -Value ([string]$definition.command_path) -RepositoryRelative
    $workingDirectory = Expand-ManagedPath -Value ([string]$definition.working_directory) -RepositoryRelative
    if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) { throw "Managed command is missing: $($definition.name)" }
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) { throw "Managed working directory is missing: $($definition.name)" }
    if ([string]$definition.safety_classification -notin @('read_only', 'local_state_write')) {
        throw "Managed unattended job has an invalid safety classification: $($definition.name)"
    }

    $credentialRefs = [Collections.Generic.List[string]]::new()
    foreach ($profileId in @($definition.required_access_profiles)) {
        $profile = $profiles[[string]$profileId]
        if (-not $profile) { throw "Required access profile '$profileId' is not defined for $($definition.name)." }
        $credentialRef = [string]$profile.credential_ref
        if ($credentialRef -notmatch '^[0-9a-fA-F-]{36}$') {
            throw "Required access profile '$profileId' has no DPAPI record identifier."
        }
        $credentialRefs.Add($credentialRef)
    }

    $endpoints = @($definition.required_endpoints | ForEach-Object {
        $port = [int]$_.port
        if ([string]::IsNullOrWhiteSpace([string]$_.host) -or $port -lt 1 -or $port -gt 65535) {
            throw "Invalid required endpoint for $($definition.name)."
        }
        [ordered]@{ host = [string]$_.host; port = $port }
    })
    $artifacts = @($definition.expected_artifacts | ForEach-Object { Expand-ManagedPath -Value ([string]$_) })
    $dependencyManifest = @(Resolve-DependencyManifest -Definition $definition -CommandPath $commandPath)

    [pscustomobject]@{
        id = [string]$definition.id
        name = [string]$definition.name
        payload = [ordered]@{
            job_type = 'recurring'
            name = [string]$definition.name
            description = [string]$definition.description
            schedule = [string]$definition.schedule
            timezone = [string]$definition.timezone
            command_type = [string]$definition.command_type
            command_path = $commandPath
            arguments = @($definition.arguments)
            working_directory = $workingDirectory
            enabled = [bool]$definition.enabled
            unattended = [bool]$definition.unattended
            timeout_seconds = [int]$definition.timeout_seconds
            overlap_policy = [string]$definition.overlap_policy
            misfire_policy = [string]$definition.misfire_policy
            capture_output = [bool]$definition.capture_output
            auto_archive = $false
            safety_classification = [string]$definition.safety_classification
            required_credential_refs = @($credentialRefs)
            required_endpoints = $endpoints
            expected_artifacts = $artifacts
            dependency_manifest = $dependencyManifest
            wake_condition = 'always'
        }
        command_sha256 = (Get-FileHash -LiteralPath $commandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        dependency_policy = [string]$definition.dependency_policy
    }
}

if (-not $Apply) {
    @($resolvedDefinitions | ForEach-Object {
        [pscustomobject]@{
            id = $_.id
            name = $_.name
            action = 'plan_only'
            command_sha256 = $_.command_sha256
            safety_classification = $_.payload.safety_classification
            required_credential_count = @($_.payload.required_credential_refs).Count
            required_endpoint_count = @($_.payload.required_endpoints).Count
            expected_artifact_count = @($_.payload.expected_artifacts).Count
            dependency_count = @($_.payload.dependency_manifest).Count
            dependency_policy = $_.dependency_policy
        }
    })
    return
}

$session = $null
$landing = Invoke-WebRequest -Uri $EngineUri -SessionVariable session -UseBasicParsing
$csrfMatch = [regex]::Match($landing.Content, '<meta\s+name="csrf-token"\s+content="([^"]+)"')
if (-not $csrfMatch.Success) { throw 'The local Job Engine did not provide a CSRF token.' }
$origin = $EngineUri.GetLeftPart([System.UriPartial]::Authority)
$headers = @{ Origin = $origin; 'X-CSRF-Token' = $csrfMatch.Groups[1].Value }
$stateUri = [uri]::new($EngineUri, 'api/state')
$state = Invoke-RestMethod -Uri $stateUri -WebSession $session -Method Get
$results = [Collections.Generic.List[object]]::new()

foreach ($definition in $resolvedDefinitions) {
    $existing = @($state.jobs | Where-Object name -eq $definition.name)
    if ($existing.Count -gt 1) { throw "More than one active Job Engine entry is named '$($definition.name)'." }
    $stagedPayload = [ordered]@{}
    foreach ($key in $definition.payload.Keys) { $stagedPayload[$key] = $definition.payload[$key] }
    $stagedPayload.enabled = $false
    if ($existing.Count -eq 1) {
        $endpoint = [uri]::new($EngineUri, "api/jobs/$($existing[0].id)/update")
        $job = Invoke-RestMethod -Uri $endpoint -WebSession $session -Headers $headers -Method Post `
            -ContentType 'application/json' -Body ($stagedPayload | ConvertTo-Json -Depth 8)
        $operation = 'updated'
    }
    else {
        $endpoint = [uri]::new($EngineUri, 'api/jobs')
        $job = Invoke-RestMethod -Uri $endpoint -WebSession $session -Headers $headers -Method Post `
            -ContentType 'application/json' -Body ($stagedPayload | ConvertTo-Json -Depth 8)
        $operation = 'created'
    }

    $preflightUri = [uri]::new($EngineUri, "api/jobs/$($job.id)/preflight")
    $preflight = Invoke-RestMethod -Uri $preflightUri -WebSession $session -Headers $headers -Method Post `
        -ContentType 'application/json' -Body '{}'
    if (-not $preflight.ok) {
        throw "Preflight failed for '$($definition.name)'; the managed job was left disabled."
    }

    if ([bool]$definition.payload.enabled) {
        $updateUri = [uri]::new($EngineUri, "api/jobs/$($job.id)/update")
        $job = Invoke-RestMethod -Uri $updateUri -WebSession $session -Headers $headers -Method Post `
            -ContentType 'application/json' -Body ($definition.payload | ConvertTo-Json -Depth 8)
        $preflight = Invoke-RestMethod -Uri $preflightUri -WebSession $session -Headers $headers -Method Post `
            -ContentType 'application/json' -Body '{}'
        if (-not $preflight.ok) {
            try {
                $job = Invoke-RestMethod -Uri $updateUri -WebSession $session -Headers $headers -Method Post `
                    -ContentType 'application/json' -Body ($stagedPayload | ConvertTo-Json -Depth 8)
            }
            catch {
                throw "Final preflight failed for '$($definition.name)' and the disable rollback also failed; Engine preflight remains fail-closed."
            }
            throw "Final preflight failed for '$($definition.name)'; the managed job was disabled again."
        }
    }
    $results.Add([pscustomobject]@{
        name = $job.name
        operation = $operation
        enabled = [bool]$job.enabled
        safety_classification = [string]$job.safety_classification
        command_hash_matches_plan = ([string]$job.command_sha256 -eq $definition.command_sha256)
        dependency_manifest_matches_plan = @($definition.payload.dependency_manifest | Where-Object {
            $expected = $_
            -not @($job.dependency_manifest | Where-Object {
                [string]::Equals([string]$_.path, [string]$expected.path, [StringComparison]::OrdinalIgnoreCase) -and
                [string]$_.sha256 -eq [string]$expected.sha256 -and
                [string]$_.role -eq [string]$expected.role
            }).Count
        }).Count -eq 0 -and @($job.dependency_manifest).Count -eq @($definition.payload.dependency_manifest).Count
        preflight_passed = [bool]$preflight.ok
        next_run_at = $job.next_run_at
    })
}

@($results)
if (@($results | Where-Object {
    -not $_.enabled -or -not $_.preflight_passed -or -not $_.command_hash_matches_plan -or -not $_.dependency_manifest_matches_plan
}).Count -gt 0) {
    throw 'One or more managed Homelab jobs failed post-registration verification.'
}
