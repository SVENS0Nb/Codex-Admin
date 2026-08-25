Describe 'Managed Homelab recurring jobs' {
    BeforeAll {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $definitionPath = Join-Path $repositoryRoot 'config\job-definitions.json'
        $definitions = Get-Content -Raw -LiteralPath $definitionPath | ConvertFrom-Json
    }

    It 'has a supported schema and unique identifiers and names' {
        [int]$definitions.schema_version | Should -Be 2
        @($definitions.jobs).Count | Should -Be 5
        @($definitions.jobs.id | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
        @($definitions.jobs.name | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
    }

    It 'resolves every command and artifact through the plan-only synchronizer' {
        $plan = @(& (Join-Path $repositoryRoot 'scripts\Sync-HomelabRecurringJobs.ps1'))
        $plan.Count | Should -Be 5
        @($plan | Where-Object action -ne 'plan_only').Count | Should -Be 0
        @($plan | Where-Object { $_.command_sha256 -notmatch '^[0-9a-f]{64}$' }).Count | Should -Be 0
        @($plan | Where-Object { [int]$_.dependency_count -lt 1 }).Count | Should -Be 0
        @($plan | Where-Object { $_.safety_classification -notin @('read_only', 'local_state_write') }).Count | Should -Be 0
    }

    It 'declares explicit repository dependency scopes for every unattended job' {
        @($definitions.jobs | Where-Object { @($_.dependency_paths).Count -eq 0 }).Count | Should -Be 0
        @($definitions.jobs | Where-Object id -in @(
            'weekly-control-plane-quality-gate',
            'monthly-control-plane-recovery-point'
        ) | Where-Object { '@repository-files' -notin @($_.dependency_paths) }).Count | Should -Be 0
    }

    It 'keeps monitored outage targets outside hard preflight requirements' {
        $availability = $definitions.jobs | Where-Object id -eq 'home-assistant-availability'
        $daily = $definitions.jobs | Where-Object id -eq 'homelab-daily-log-review'
        @($availability.required_endpoints).Count | Should -Be 0
        @($daily.required_endpoints).Count | Should -Be 0
        [string]$availability.dependency_policy | Should -Match 'must produce a probe record'
        [string]$daily.dependency_policy | Should -Match 'coverage'
    }

    It 'requires an explicit DPAPI-backed access profile for the UniFi archive' {
        $unifi = $definitions.jobs | Where-Object id -eq 'unifi-security-event-archive'
        @($unifi.required_access_profiles).Count | Should -Be 1
        [string]$unifi.required_access_profiles[0] | Should -Be 'unifi-console-ssh'
        @($unifi.required_endpoints).Count | Should -Be 1
        [int]$unifi.required_endpoints[0].port | Should -Be 22
    }

    It 'never enables output capture for managed jobs' {
        @($definitions.jobs | Where-Object { $_.capture_output }).Count | Should -Be 0
    }

    It 'leaves a newly created job disabled when staged preflight fails' {
        $global:HomelabSubmittedBodies = [Collections.Generic.List[object]]::new()
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '<meta name="csrf-token" content="fixture-csrf">' } }
        Mock Invoke-RestMethod {
            if ($Uri.AbsolutePath -eq '/api/state') { return [pscustomobject]@{ jobs = @() } }
            if ($Uri.AbsolutePath -eq '/api/jobs') {
                $payload = $Body | ConvertFrom-Json
                $global:HomelabSubmittedBodies.Add($payload)
                $payload | Add-Member -NotePropertyName id -NotePropertyValue '11111111-1111-4111-8111-111111111111'
                $payload | Add-Member -NotePropertyName command_sha256 -NotePropertyValue `
                    ((Get-FileHash -LiteralPath $payload.command_path -Algorithm SHA256).Hash.ToLowerInvariant())
                return $payload
            }
            if ($Uri.AbsolutePath -match '/preflight$') { return [pscustomobject]@{ ok = $false } }
            throw "Unexpected fixture URI: $($Uri.AbsolutePath)"
        }

        $observedError = $null
        try {
            & (Join-Path $repositoryRoot 'scripts\Sync-HomelabRecurringJobs.ps1') -Apply `
                -Name 'Homelab control-plane quality gate' -EngineUri 'http://127.0.0.1:18770/' | Out-Null
        }
        catch { $observedError = $_.Exception.Message }
        [string]$observedError | Should -Match 'left disabled'
        $global:HomelabSubmittedBodies.Count | Should -Be 1
        [bool]$global:HomelabSubmittedBodies[0].enabled | Should -Be $false
        Remove-Variable -Name HomelabSubmittedBodies -Scope Global -ErrorAction SilentlyContinue
    }

    It 'enables a staged job only after both preflight checks succeed' {
        $global:HomelabSubmittedBodies = [Collections.Generic.List[object]]::new()
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '<meta name="csrf-token" content="fixture-csrf">' } }
        Mock Invoke-RestMethod {
            if ($Uri.AbsolutePath -eq '/api/state') { return [pscustomobject]@{ jobs = @() } }
            if ($Uri.AbsolutePath -eq '/api/jobs' -or $Uri.AbsolutePath -match '/update$') {
                $payload = $Body | ConvertFrom-Json
                $global:HomelabSubmittedBodies.Add($payload)
                $payload | Add-Member -NotePropertyName id -NotePropertyValue '22222222-2222-4222-8222-222222222222' -Force
                $payload | Add-Member -NotePropertyName command_sha256 -NotePropertyValue `
                    ((Get-FileHash -LiteralPath $payload.command_path -Algorithm SHA256).Hash.ToLowerInvariant()) -Force
                $payload | Add-Member -NotePropertyName next_run_at -NotePropertyValue '2026-09-01T02:00:00.000Z' -Force
                return $payload
            }
            if ($Uri.AbsolutePath -match '/preflight$') { return [pscustomobject]@{ ok = $true } }
            throw "Unexpected fixture URI: $($Uri.AbsolutePath)"
        }

        $result = @(& (Join-Path $repositoryRoot 'scripts\Sync-HomelabRecurringJobs.ps1') -Apply `
            -Name 'Homelab control-plane quality gate' -EngineUri 'http://127.0.0.1:18770/')
        $result.Count | Should -Be 1
        $result[0].preflight_passed | Should -Be $true
        $global:HomelabSubmittedBodies.Count | Should -Be 2
        [bool]$global:HomelabSubmittedBodies[0].enabled | Should -Be $false
        [bool]$global:HomelabSubmittedBodies[1].enabled | Should -Be $true
        Remove-Variable -Name HomelabSubmittedBodies -Scope Global -ErrorAction SilentlyContinue
    }
}
