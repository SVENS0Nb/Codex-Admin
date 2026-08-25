[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$resolvedBackup = (Resolve-Path -LiteralPath $BackupPath).Path
$approvedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexAdmin\control-plane\backups'))
if (-not $resolvedBackup.StartsWith($approvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Control-plane backup path is outside the approved local backup root.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('homelab-agent-restore-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $restoredCodex = Join-Path $temporaryRoot 'codex'
    $restoredRepository = Join-Path $temporaryRoot 'repository'
    Copy-Item -LiteralPath (Join-Path $resolvedBackup 'codex') -Destination $restoredCodex -Recurse

    $bundlePath = Join-Path $resolvedBackup 'repository\homelab-ops.bundle'
    & git clone --quiet $bundlePath $restoredRepository
    if ($LASTEXITCODE -ne 0) { throw 'The Git bundle could not be restored into the isolated test directory.' }

    $skillPath = Join-Path $restoredCodex 'homelab-admin-skill\SKILL.md'
    $agentsPath = Join-Path $restoredCodex 'AGENTS.md'
    $mcpPath = Join-Path $restoredCodex 'homelab-admin-mcp.toml'
    foreach ($required in @($skillPath, $agentsPath, $mcpPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf) -or (Get-Item -LiteralPath $required).Length -le 0) {
            throw "Required restored agent asset is missing: $([IO.Path]::GetFileName($required))"
        }
    }

    $skill = Get-Content -Raw -LiteralPath $skillPath -Encoding utf8
    $skillOk = $skill -match '(?ms)^---\s*\r?\nname:\s*homelab-admin\s*\r?\ndescription:.+?\r?\n---' -and
        $skill -match '\bcontext_bootstrap\b' -and
        $skill -match '(?i)confirmation|Bestätigung'
    $agents = Get-Content -Raw -LiteralPath $agentsPath -Encoding utf8
    $agentsOk = $agents -match 'Dedicated Codex homelab administrator' -and
        $agents -match '\bcontext_bootstrap\b' -and
        $agents -match '(?i)reachability|Erreichbarkeit'

    & python.exe -c 'import pathlib,sys,tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' $mcpPath
    $tomlOk = $LASTEXITCODE -eq 0
    $mcp = Get-Content -Raw -LiteralPath $mcpPath -Encoding utf8
    $mcpSectionOk = $mcp -match '(?m)^\[mcp_servers\.homelab_admin\]\s*$' -and
        $mcp -match '(?m)^command\s*=\s*"node"\s*$'
    $argumentMatch = [regex]::Match($mcp, '(?m)^args\s*=\s*\[\s*"([^"]+)"\s*\]\s*$')
    if (-not $argumentMatch.Success) { throw 'Restored MCP fragment has no single allowlisted entrypoint.' }
    $configuredEntrypoint = [IO.Path]::GetFullPath($argumentMatch.Groups[1].Value.Replace('\\', '\'))
    $relativeEntrypoint = [IO.Path]::Combine('mcp', 'homelab-admin', 'build', 'index.js')
    $expectedSuffix = [IO.Path]::DirectorySeparatorChar + $relativeEntrypoint
    if (-not $configuredEntrypoint.EndsWith($expectedSuffix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Restored MCP entrypoint does not use the allowlisted repository-relative path.'
    }
    $isolatedEntrypoint = [IO.Path]::GetFullPath((Join-Path $restoredRepository $relativeEntrypoint))
    $entrypointOk = $isolatedEntrypoint.StartsWith(
        [IO.Path]::GetFullPath($restoredRepository) + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -and (Test-Path -LiteralPath $isolatedEntrypoint -PathType Leaf)

    $combinedText = $skill + "`n" + $agents + "`n" + $mcp
    $forbidden = @(
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',
        '(?i)otpauth://',
        '(?i)\bBearer\s+[A-Za-z0-9._~+/-]{16,}',
        '(?i)\b(password|passphrase|token|secret|authorization)\s*[:=]\s*[^\s#]+'
    )
    $secretScanOk = @($forbidden | Where-Object { $combinedText -match $_ }).Count -eq 0
    $success = $skillOk -and $agentsOk -and $tomlOk -and $mcpSectionOk -and $entrypointOk -and $secretScanOk

    [pscustomobject]@{
        success = [bool]$success
        isolated_restore = $true
        live_paths_modified = $false
        repository_bundle_restored = Test-Path -LiteralPath (Join-Path $restoredRepository '.git') -PathType Container
        skill_ok = [bool]$skillOk
        global_agents_ok = [bool]$agentsOk
        mcp_toml_ok = [bool]($tomlOk -and $mcpSectionOk)
        mcp_entrypoint_ok = [bool]$entrypointOk
        secret_scan_ok = [bool]$secretScanOk
        accepted_constraints = @(
            'The encrypted DPAPI secret vault is excluded unless explicitly requested.',
            'Recovery points remain on the dedicated admin VM and therefore share its failure domain.',
            'Recovery-point deletion is never automatic.',
            'Agent assets are restore-tested only in an isolated temporary directory and never overwrite live Codex paths.'
        )
    }
}
finally {
    $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedTemporary.StartsWith($systemTemporary, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTemporary) -like 'homelab-agent-restore-*') {
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
    }
}
