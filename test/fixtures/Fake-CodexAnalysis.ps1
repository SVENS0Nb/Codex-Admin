$statePath = [string]$env:HOMELAB_FAKE_ANALYZER_STATE
$mode = [string]$env:HOMELAB_FAKE_ANALYZER_MODE
$count = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    [int](Get-Content -Raw -LiteralPath $statePath)
} else { 0 }
$count++
[IO.File]::WriteAllText($statePath, [string]$count)

if ($mode -eq 'always_fail' -or ($mode -eq 'fail_once' -and $count -eq 1)) {
    [Console]::Error.WriteLine("simulated analyzer failure $count")
    exit 17
}

$outputIndex = [Array]::IndexOf([object[]]$args, '-o')
if ($outputIndex -lt 0 -or $outputIndex + 1 -ge $args.Count) {
    [Console]::Error.WriteLine('missing output path')
    exit 18
}
[IO.File]::WriteAllText([string]$args[$outputIndex + 1], [string]$env:HOMELAB_FAKE_ANALYZER_JSON, [Text.UTF8Encoding]::new($false))
exit 0
