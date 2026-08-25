[CmdletBinding()]
param(
    [switch]$SkipCleanClone,
    [switch]$NoFail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$results = [Collections.Generic.List[object]]::new()

function Invoke-Check {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action | Out-Null
        $results.Add([pscustomobject]@{ name=$Name; passed=$true; duration_ms=$watch.ElapsedMilliseconds; error=$null })
    } catch {
        $safe = [string]$_.Exception.Message
        $safe = $safe -replace '(?i)\b(Bearer|token|password|secret|authorization)\s*[:=]\s*\S+', '$1=[REDACTED]'
        if ($safe.Length -gt 500) { $safe = $safe.Substring(0,500) }
        $results.Add([pscustomobject]@{ name=$Name; passed=$false; duration_ms=$watch.ElapsedMilliseconds; error=$safe })
    } finally { $watch.Stop() }
}

$files = @(& git -C $repositoryRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate project files.' }

Invoke-Check 'publication-safety' {
    $json = & pwsh.exe -NoLogo -NoProfile -File (Join-Path $repositoryRoot 'scripts\Test-CodexAdminPublicationSafety.ps1') -NoFail
    $scan = $json | ConvertFrom-Json
    if (-not $scan.success) { throw "Publication scan found $($scan.finding_count) issue(s)." }
}

Invoke-Check 'powershell-parser' {
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($relative in @($files | Where-Object { [IO.Path]::GetExtension($_) -in @('.ps1','.psm1','.psd1') })) {
        $tokens = $null; $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot $relative), [ref]$tokens, [ref]$parseErrors) | Out-Null
        foreach ($parseError in @($parseErrors)) { $errors.Add("${relative}:$($parseError.Extent.StartLineNumber)") }
    }
    if ($errors.Count -gt 0) { throw "PowerShell parser failures: $($errors -join ', ')" }
}

Invoke-Check 'json-parser' {
    $bad = [Collections.Generic.List[string]]::new()
    foreach ($relative in @($files | Where-Object { [IO.Path]::GetExtension($_) -eq '.json' })) {
        try { Get-Content -LiteralPath (Join-Path $repositoryRoot $relative) -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop | Out-Null }
        catch { $bad.Add($relative) }
    }
    if ($bad.Count -gt 0) { throw "Invalid JSON: $($bad -join ', ')" }
}

Invoke-Check 'python-ast' {
    $pythonFiles = @($files | Where-Object { [IO.Path]::GetExtension($_) -eq '.py' } | ForEach-Object { Join-Path $repositoryRoot $_ })
    if ($pythonFiles.Count -gt 0) {
        & python.exe -c 'import ast,pathlib,sys; [ast.parse(pathlib.Path(p).read_text(encoding="utf-8"), filename=p) for p in sys.argv[1:]]' @pythonFiles
        if ($LASTEXITCODE -ne 0) { throw 'Python AST validation failed.' }
    }
}

foreach ($project in @(
    @{name='homelab-mcp';path='mcp\homelab-admin'},
    @{name='job-engine';path='apps\job-engine'},
    @{name='secret-ui';path='apps\secret-ui'},
    @{name='unifi-security-log';path='apps\unifi-security-log'}
)) {
    Invoke-Check "node-tests:$($project.name)" {
        Push-Location (Join-Path $repositoryRoot $project.path)
        try { & npm.cmd test; if ($LASTEXITCODE -ne 0) { throw "Node tests failed for $($project.name)." } }
        finally { Pop-Location }
    }
}

Invoke-Check 'pester' {
    $module = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) { throw 'Pester is unavailable.' }
    if ($module.Version.Major -ge 5) {
        $pester = Invoke-Pester -Path (Join-Path $repositoryRoot 'test\powershell') -PassThru
    } else {
        $pester = Invoke-Pester -Script (Join-Path $repositoryRoot 'test\powershell') -PassThru
    }
    if ($pester.FailedCount -gt 0) { throw "Pester reported $($pester.FailedCount) failure(s)." }
}

Invoke-Check 'synthetic-knowledge-database' {
    $temporaryLocal = Join-Path ([IO.Path]::GetTempPath()) ('codex-admin-db-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryLocal | Out-Null
    $previousLocal = $env:LOCALAPPDATA
    $previousSite = [Environment]::GetEnvironmentVariable('CODEX_ADMIN_SITE_ROOT','Process')
    try {
        $env:LOCALAPPDATA = $temporaryLocal
        $env:CODEX_ADMIN_SITE_ROOT = Join-Path $temporaryLocal 'site'
        New-Item -ItemType Directory -Path $env:CODEX_ADMIN_SITE_ROOT | Out-Null
        & node.exe (Join-Path $repositoryRoot 'mcp\homelab-admin\build\cli.js') init | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Synthetic knowledge initialization failed.' }
        $integrity = & node.exe (Join-Path $repositoryRoot 'mcp\homelab-admin\build\cli.js') integrity | ConvertFrom-Json
        if (-not $integrity.ok) { throw 'Synthetic knowledge integrity failed.' }
    } finally {
        $env:LOCALAPPDATA = $previousLocal
        if ($null -eq $previousSite) { [Environment]::SetEnvironmentVariable('CODEX_ADMIN_SITE_ROOT',$null,'Process') } else { $env:CODEX_ADMIN_SITE_ROOT=$previousSite }
        if (Test-Path -LiteralPath $temporaryLocal) { Remove-Item -LiteralPath $temporaryLocal -Recurse -Force }
    }
}

if (-not $SkipCleanClone) {
    Invoke-Check 'clean-clone-install' {
        $head = (& git -C $repositoryRoot rev-parse --verify HEAD 2>$null).Trim()
        if (-not $head) { throw 'A committed Git revision is required for the clean-clone test.' }
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-admin-clone-' + [guid]::NewGuid().ToString('N'))
        $clone = Join-Path $temporaryRoot 'repository'
        $testLocal = Join-Path $temporaryRoot 'localappdata'
        $site = Join-Path $temporaryRoot 'site'
        New-Item -ItemType Directory -Path $temporaryRoot,$testLocal | Out-Null
        $previousLocal = $env:LOCALAPPDATA
        $previousSite = [Environment]::GetEnvironmentVariable('CODEX_ADMIN_SITE_ROOT','Process')
        try {
            & git clone --quiet --no-local $repositoryRoot $clone
            if ($LASTEXITCODE -ne 0) { throw 'Clean clone failed.' }
            $env:LOCALAPPDATA = $testLocal
            $env:CODEX_ADMIN_SITE_ROOT = $site
            & pwsh.exe -NoLogo -NoProfile -File (Join-Path $clone 'scripts\Install-CodexAdmin.ps1') -SiteRoot $site | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Clean-clone installation failed.' }
            & pwsh.exe -NoLogo -NoProfile -File (Join-Path $clone 'scripts\Test-CodexAdminPublicProject.ps1') -SkipCleanClone
            if ($LASTEXITCODE -ne 0) { throw 'Clean-clone project tests failed.' }
        } finally {
            $env:LOCALAPPDATA = $previousLocal
            if ($null -eq $previousSite) { [Environment]::SetEnvironmentVariable('CODEX_ADMIN_SITE_ROOT',$null,'Process') } else { $env:CODEX_ADMIN_SITE_ROOT=$previousSite }
            if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
        }
    }
}

$failed = @($results | Where-Object { -not $_.passed })
$summary = [pscustomobject]@{
    success = $failed.Count -eq 0
    generated_at = [DateTimeOffset]::Now.ToString('o')
    total = $results.Count
    passed = $results.Count - $failed.Count
    failed = $failed.Count
    clean_clone_tested = -not $SkipCleanClone
    results = @($results)
}
$summary
if (-not $NoFail -and $failed.Count -gt 0) { exit 1 }
