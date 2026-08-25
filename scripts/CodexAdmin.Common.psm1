Set-StrictMode -Version Latest

function Get-CodexAdminSiteRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $configured = [Environment]::GetEnvironmentVariable('CODEX_ADMIN_SITE_ROOT')
    if ([string]::IsNullOrWhiteSpace($configured)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable and CODEX_ADMIN_SITE_ROOT is not set.'
        }
        $configured = Join-Path $env:LOCALAPPDATA 'CodexAdmin\site'
    }
    $site = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($configured))
    if ($site.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
        $site.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The private site root must remain outside the Git repository.'
    }
    $site
}

function Resolve-CodexAdminDataPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$AllowMissing
    )

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw 'RelativePath must be repository-relative.'
    }
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $normalized = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar).Replace('\', [IO.Path]::DirectorySeparatorChar)
    $repositoryPath = [IO.Path]::GetFullPath((Join-Path $repository $normalized))
    if (-not $repositoryPath.StartsWith($repository + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RelativePath escaped the repository root.'
    }

    $overlayAllowed = $normalized.StartsWith('inventory' + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $normalized -in @('config' + [IO.Path]::DirectorySeparatorChar + 'daily-log-review.json', 'config' + [IO.Path]::DirectorySeparatorChar + 'job-definitions.json')
    if ($overlayAllowed) {
        $siteRoot = Get-CodexAdminSiteRoot -RepositoryRoot $repository
        $sitePath = [IO.Path]::GetFullPath((Join-Path $siteRoot $normalized))
        if (-not $sitePath.StartsWith($siteRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'RelativePath escaped the private site root.'
        }
        if (Test-Path -LiteralPath $sitePath -PathType Leaf) { return $sitePath }
    }

    if ((Test-Path -LiteralPath $repositoryPath -PathType Leaf) -or $AllowMissing) { return $repositoryPath }
    throw "Required Codex-Admin data file is missing: $RelativePath"
}

Export-ModuleMember -Function Get-CodexAdminSiteRoot, Resolve-CodexAdminDataPath
