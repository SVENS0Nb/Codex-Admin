[CmdletBinding()]
param(
    [switch]$NoFail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$maximumBytes = 5MB

$relativePaths = @(& git -C $repositoryRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate repository files.' }

$forbiddenPrefixes = @('artifacts/', '.site/', 'reports/', 'database/backups/')
$textExtensions = @('.ps1','.psm1','.psd1','.py','.mjs','.js','.ts','.json','.md','.toml','.sql','.cmd','.css','.html','.yml','.yaml','.txt','.xml','.service','.nft')
$findings = [Collections.Generic.List[object]]::new()
$filesScanned = 0

function Add-Finding {
    param([string]$Rule, [string]$Path, [int]$Line = 0)
    $findings.Add([pscustomobject]@{ rule = $Rule; path = $Path.Replace('\','/'); line = $Line })
}

$secretRules = [ordered]@{
    private_key_header = '^\s*-----BEGIN ' + '(?:OPENSSH |RSA |EC |DSA |PGP )?PRIVATE KEY-----\s*$'
    totp_uri = '(?i)\botpauth' + '://(?:totp|hotp)/[^\s]+\bsecret=[A-Z2-7]{16,}'
    openai_key = '\bsk' + '-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b'
    github_token = '\bgh' + '[pousr]_[A-Za-z0-9]{30,}\b'
    aws_access_key = '\bAK' + 'IA[0-9A-Z]{16}\b'
    jwt = '\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b'
    bearer_value = '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{24,}\b'
    url_userinfo = '(?i)https?://[^/@\s]+:[^/@\s]+@'
    certificate_pin = '(?i)\b(certificate_sha256|certificatepin|certificate_sha256)\b[^\r\n]{0,40}[0-9a-f]{64}\b'
    ssh_fingerprint = '\bSHA256:[A-Za-z0-9+/]{30,}={0,2}\b'
}

foreach ($relativePath in $relativePaths) {
    if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
    $normalized = $relativePath.Replace('\','/')
    foreach ($prefix in $forbiddenPrefixes) {
        if ($normalized.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            Add-Finding -Rule 'forbidden_tracked_path' -Path $normalized
        }
    }
    if ([IO.Path]::GetExtension($normalized) -match '^\.(?:key|pem|pfx|p12|sqlite|sqlite3|log)$') {
        Add-Finding -Rule 'forbidden_file_type' -Path $normalized
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $relativePath))
    if (-not $fullPath.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Repository enumeration escaped the repository root.'
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
    $info = Get-Item -LiteralPath $fullPath
    if ($info.Length -gt $maximumBytes -or ($textExtensions -notcontains $info.Extension -and $info.Name -notin @('.editorconfig','.gitattributes','.gitignore'))) { continue }
    try { $text = [IO.File]::ReadAllText($fullPath) } catch { continue }
    if ($text.Contains([char]0)) { continue }
    $filesScanned++
    $lineNumber = 0
    foreach ($line in ($text -split '\r?\n')) {
        $lineNumber++
        foreach ($rule in $secretRules.GetEnumerator()) {
            if ($line -match $rule.Value) { Add-Finding -Rule $rule.Key -Path $normalized -Line $lineNumber }
        }
        if ($line -match '(?i)\b(?:[a-z0-9-]+\.)+(?:home\.arpa|local)\b') {
            Add-Finding -Rule 'internal_dns_name' -Path $normalized -Line $lineNumber
        }
        if ($line -match '(?i)C:\\Users\\(?!Public\\)[^\\\s]+\\') {
            Add-Finding -Rule 'user_specific_windows_path' -Path $normalized -Line $lineNumber
        }
        if ($line -match '(?i)(?<![0-9a-f])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])') {
            Add-Finding -Rule 'mac_address' -Path $normalized -Line $lineNumber
        }
        foreach ($match in [regex]::Matches($line, '(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)')) {
            $value = $match.Value
            $parts = @($value.Split('.') | ForEach-Object { [int]$_ })
            if ($parts.Count -ne 4 -or @($parts | Where-Object { $_ -gt 255 }).Count -gt 0) { continue }
            $allowed = $value -eq '0.0.0.0' -or $parts[0] -eq 127 -or
                ($parts[0] -eq 192 -and $parts[1] -eq 0 -and $parts[2] -eq 2) -or
                ($parts[0] -eq 198 -and $parts[1] -eq 51 -and $parts[2] -eq 100) -or
                ($parts[0] -eq 203 -and $parts[1] -eq 0 -and $parts[2] -eq 113)
            if (-not $allowed) { Add-Finding -Rule 'non_example_ipv4' -Path $normalized -Line $lineNumber }
        }
        if ($normalized.StartsWith('scripts/', [StringComparison]::OrdinalIgnoreCase)) {
            foreach ($match in [regex]::Matches($line, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b')) {
                if (-not $match.Value.StartsWith('00000000-0000-4000-8000-0000000000')) {
                    Add-Finding -Rule 'literal_runtime_identifier' -Path $normalized -Line $lineNumber
                }
            }
        }
    }
}

$deduplicated = @($findings | Sort-Object rule,path,line -Unique)
$result = [ordered]@{
    success = $deduplicated.Count -eq 0
    files_scanned = $filesScanned
    files_enumerated = $relativePaths.Count
    finding_count = $deduplicated.Count
    findings = $deduplicated
}
$result | ConvertTo-Json -Depth 5
if (-not $NoFail -and $deduplicated.Count -gt 0) { exit 1 }
