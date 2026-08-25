[CmdletBinding()]
param(
    [switch]$NoFail
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$results = [Collections.Generic.List[object]]::new()

function Protect-QualityError {
    param([AllowNull()][object]$Value)
    $text = [string]$Value
    $text = $text -replace '(?i)\b(Bearer|token|password|secret|authorization)\s*[:=]\s*\S+', '$1=[REDACTED]'
    if ($text.Length -gt 500) { $text = $text.Substring(0, 500) }
    $text
}

function Invoke-QualityStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $started = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action | Out-Null
        $results.Add([pscustomobject]@{ name = $Name; passed = $true; duration_ms = $started.ElapsedMilliseconds; error = $null })
    }
    catch {
        $results.Add([pscustomobject]@{ name = $Name; passed = $false; duration_ms = $started.ElapsedMilliseconds; error = Protect-QualityError $_.Exception.Message })
    }
    finally { $started.Stop() }
}

$repositoryFiles = @(& git -C $repositoryRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate repository files.' }

Invoke-QualityStep -Name 'powershell-parser' -Action {
    $parseErrors = [Collections.Generic.List[string]]::new()
    foreach ($relative in @($repositoryFiles | Where-Object { [IO.Path]::GetExtension($_) -in @('.ps1', '.psm1', '.psd1') })) {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot $relative), [ref]$tokens, [ref]$errors) | Out-Null
        foreach ($error in @($errors)) { $parseErrors.Add("${relative}:$($error.Extent.StartLineNumber)") }
    }
    if ($parseErrors.Count -gt 0) { throw "PowerShell parser failures: $($parseErrors -join ', ')" }
}

Invoke-QualityStep -Name 'json-parser' -Action {
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($relative in @($repositoryFiles | Where-Object { [IO.Path]::GetExtension($_) -eq '.json' })) {
        try { Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot $relative) | ConvertFrom-Json -AsHashtable -ErrorAction Stop | Out-Null }
        catch { $failures.Add($relative) }
    }
    if ($failures.Count -gt 0) { throw "JSON parser failures: $($failures -join ', ')" }
}

Invoke-QualityStep -Name 'python-ast' -Action {
    $pythonFiles = @($repositoryFiles | Where-Object { [IO.Path]::GetExtension($_) -eq '.py' } | ForEach-Object { Join-Path $repositoryRoot $_ })
    if ($pythonFiles.Count -gt 0) {
        $program = 'import ast,pathlib,sys; failures=[]; [(ast.parse(pathlib.Path(p).read_text(encoding="utf-8"), filename=p)) for p in sys.argv[1:]]'
        & python.exe -c $program @pythonFiles *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Python AST validation failed.' }
    }
}

foreach ($nodeProject in @(
    @{ name = 'homelab-mcp'; path = 'mcp\homelab-admin' },
    @{ name = 'job-engine'; path = 'apps\job-engine' },
    @{ name = 'secret-ui'; path = 'apps\secret-ui' },
    @{ name = 'unifi-security-log'; path = 'apps\unifi-security-log' }
)) {
    Invoke-QualityStep -Name "node-tests:$($nodeProject.name)" -Action {
        Push-Location (Join-Path $repositoryRoot $nodeProject.path)
        try {
            & npm.cmd test *> $null
            if ($LASTEXITCODE -ne 0) { throw "Node test suite failed for $($nodeProject.name)." }
        }
        finally { Pop-Location }
    }
}

Invoke-QualityStep -Name 'pester:powershell' -Action {
    $pester = Invoke-Pester -Script (Join-Path $repositoryRoot 'test\powershell') -PassThru
    if ($pester.FailedCount -gt 0) { throw "Pester reported $($pester.FailedCount) failed test(s)." }
}

Invoke-QualityStep -Name 'repository-secret-scan' -Action {
    $scanJson = & pwsh.exe -NoLogo -NoProfile -File (Join-Path $repositoryRoot 'scripts\Test-HomelabRepositorySecrets.ps1') -NoFail
    $scan = $scanJson | ConvertFrom-Json
    if (-not $scan.success) { throw "Repository secret scan reported $(@($scan.findings).Count) high-confidence finding(s)." }
}

Invoke-QualityStep -Name 'publication-safety-scan' -Action {
    $scanJson = & pwsh.exe -NoLogo -NoProfile -File (Join-Path $repositoryRoot 'scripts\Test-CodexAdminPublicationSafety.ps1') -NoFail
    $scan = $scanJson | ConvertFrom-Json
    if (-not $scan.success) { throw "Publication safety scan reported $($scan.finding_count) finding(s)." }
}

Invoke-QualityStep -Name 'platform-health:offline' -Action {
    $health = & (Join-Path $repositoryRoot 'scripts\Get-HomelabPlatformHealth.ps1') -SkipLive
    if (-not $health.all_passed) { throw "Offline platform health reported $($health.failed_count) failed check(s)." }
}

$failed = @($results | Where-Object { -not $_.passed })
$summary = [pscustomobject]@{
    success = $failed.Count -eq 0
    generated_at = [DateTimeOffset]::Now.ToString('o')
    total = $results.Count
    passed = $results.Count - $failed.Count
    failed = $failed.Count
    results = @($results)
}
$summary
if (-not $NoFail -and $failed.Count -gt 0) { exit 1 }
