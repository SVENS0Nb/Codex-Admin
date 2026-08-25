[CmdletBinding()]
param(
    [switch]$NoFail
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$maximumBytes = 5MB
$rules = [ordered]@{
    private_key_header = '^\s*-----BEGIN (?:OPENSSH |RSA |EC |DSA |PGP )?PRIVATE KEY-----\s*$'
    totp_uri = '(?i)\botpauth' + '://(?:totp|hotp)/[^\s]+\bsecret=[A-Z2-7]{16,}'
    openai_key = '\bsk' + '-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b'
    github_token = '\bgh' + '[pousr]_[A-Za-z0-9]{30,}\b'
    aws_access_key = '\bAK' + 'IA[0-9A-Z]{16}\b'
    jwt = '\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b'
    bearer_value = '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{24,}\b'
}

$relativePaths = @(& git -C $repositoryRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate repository files for the secret scan.' }
$findings = [Collections.Generic.List[object]]::new()
$filesScanned = 0
$filesSkipped = 0

foreach ($relativePath in $relativePaths) {
    if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $relativePath))
    if (-not $fullPath.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Repository file enumeration escaped the repository root.'
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
    $info = Get-Item -LiteralPath $fullPath
    if ($info.Length -gt $maximumBytes) { $filesSkipped++; continue }
    try { $text = [IO.File]::ReadAllText($fullPath) }
    catch { $filesSkipped++; continue }
    if ($text.Contains([char]0)) { $filesSkipped++; continue }
    $filesScanned++
    $lineNumber = 0
    foreach ($line in ($text -split '\r?\n')) {
        $lineNumber++
        foreach ($rule in $rules.GetEnumerator()) {
            if ($line -match $rule.Value) {
                $findings.Add([pscustomobject]@{
                    rule = $rule.Key
                    path = $relativePath.Replace('\', '/')
                    line = $lineNumber
                })
            }
        }
    }
}

$result = [ordered]@{
    success = $findings.Count -eq 0
    files_scanned = $filesScanned
    files_skipped = $filesSkipped
    findings = @($findings)
}
$result | ConvertTo-Json -Depth 5
if (-not $NoFail -and $findings.Count -gt 0) { exit 1 }
