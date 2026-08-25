[CmdletBinding()]
param(
    [switch]$NoFail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$commits = @(& git -C $repositoryRoot rev-list --all)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate Git history.' }

$rules = [ordered]@{
    private_key_header = '-----BEGIN (OPENSSH |RSA |EC |DSA |PGP )?PRIVATE KEY-----'
    totp_uri = 'otpauth://(totp|hotp)/[^[:space:]]+secret=[A-Z2-7]{16,}'
    openai_key = 'sk-(proj-|svcacct-)?[A-Za-z0-9_-]{20,}'
    github_token = 'gh[pousr]_[A-Za-z0-9]{30,}'
    aws_access_key = 'AKIA[0-9A-Z]{16}'
    jwt = 'eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}'
    private_ipv4 = '(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
    internal_dns = '(https?|ssh)://[A-Za-z0-9.-]+\.(home\.arpa|local)|"[A-Za-z0-9.-]+\.(home\.arpa|local)(:[0-9]+)?"'
    user_path = 'C:\\Users\\Admin\\'
}
$findings = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($commit in $commits) {
    foreach ($rule in $rules.GetEnumerator()) {
        $matches = @(& git -C $repositoryRoot grep -I -l -E -e $rule.Value $commit -- 2>$null)
        if ($LASTEXITCODE -notin @(0,1)) { throw "Git history scan failed for $($rule.Key)." }
        foreach ($match in $matches) {
            $path = $match -replace '^[0-9a-f]{40}:',''
            [void]$findings.Add("$($rule.Key)|$path")
        }
    }
}
$items = @($findings | Sort-Object | ForEach-Object {
    $parts = $_ -split '\|',2
    [pscustomobject]@{ rule = $parts[0]; path = $parts[1] }
})
[ordered]@{ success = $items.Count -eq 0; commits_scanned = $commits.Count; finding_count = $items.Count; findings = $items } | ConvertTo-Json -Depth 4
if (-not $NoFail -and $items.Count -gt 0) { exit 1 }
exit 0
