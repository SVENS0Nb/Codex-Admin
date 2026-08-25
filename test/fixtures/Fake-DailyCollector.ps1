param(
    [int]$LookbackHours,
    [string]$RuntimeDirectory,
    [string]$ReportDirectory,
    [switch]$LibraryOnly
)

$script:Events = [Collections.Generic.List[object]]::new()
$script:Coverage = [Collections.Generic.List[object]]::new()

function Invoke-FixtureCollector {
    if ($env:HOMELAB_FAKE_COLLECTOR_DELAY_SECONDS) {
        Start-Sleep -Seconds ([int]$env:HOMELAB_FAKE_COLLECTOR_DELAY_SECONDS)
    }
    $script:Events.Add([pscustomobject]@{
        system_id = 'fixture'
        source = 'fixture'
        severity_hint = 'high'
        message = 'fixture event'
    })
    $script:Coverage.Add([pscustomobject]@{
        system_id = 'fixture'
        source = 'fixture'
        success = $true
        lines_read = 1
        selected_events = 1
        error = $null
    })
}

if ($LibraryOnly) { return }
