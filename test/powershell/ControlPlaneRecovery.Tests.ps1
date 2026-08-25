Describe 'Isolated Homelab control-plane agent restore' {
    BeforeAll {
    $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('homelab-control-plane-recovery-' + [guid]::NewGuid().ToString('N'))
    $previousLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $testRoot

    $backupPath = Join-Path $testRoot 'CodexAdmin\control-plane\backups\fixture'
    $codexPath = Join-Path $backupPath 'codex'
    $repositoryPath = Join-Path $backupPath 'repository'
    New-Item -ItemType Directory -Path $codexPath, $repositoryPath -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'skills\homelab-admin') `
        -Destination (Join-Path $codexPath 'homelab-admin-skill') -Recurse
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'AGENTS.md') `
        -Destination (Join-Path $codexPath 'AGENTS.md')
    $mcp = @'
# Test recovery fragment without credentials.
[mcp_servers.homelab_admin]
command = "node"
args = ["C:\\Codex-Admin\\mcp\\homelab-admin\\build\\index.js"]
'@
    Set-Content -LiteralPath (Join-Path $codexPath 'homelab-admin-mcp.toml') -Encoding utf8NoBOM -Value $mcp
    & git -C $repositoryRoot bundle create (Join-Path $repositoryPath 'homelab-ops.bundle') --all
    if ($LASTEXITCODE -ne 0) { throw 'Fixture Git bundle creation failed.' }

    }

    It 'restores and validates agent assets without modifying live paths' {
            $result = & (Join-Path $repositoryRoot 'scripts\Test-HomelabControlPlaneAgentRestore.ps1') `
                -BackupPath $backupPath
            $result.success | Should -Be $true
            $result.live_paths_modified | Should -Be $false
            $result.repository_bundle_restored | Should -Be $true
            $result.mcp_entrypoint_ok | Should -Be $true
            $result.secret_scan_ok | Should -Be $true
    }

    AfterAll {
    if ($null -eq $previousLocalAppData) {
        Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue
    }
    else {
        $env:LOCALAPPDATA = $previousLocalAppData
    }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'homelab-control-plane-recovery-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    }
}
