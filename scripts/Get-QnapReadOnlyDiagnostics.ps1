[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$rootHelper = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-QnapRootCommand.ps1')).Path

$remoteCommand = @'
printf '__HOSTNAME__=%s\n' "$(hostname)"
printf '__MODEL__=%s\n' "$(/sbin/getsysinfo model 2>/dev/null)"
printf '__INTERNAL_MODEL__=%s\n' "$(/sbin/getcfg System Model -f /etc/config/uLinux.conf 2>/dev/null)"
printf '__QTS_VERSION__=%s\n' "$(/sbin/getcfg System Version -f /etc/config/uLinux.conf 2>/dev/null)"
printf '__QTS_BUILD__=%s\n' "$(/sbin/getcfg System 'Build Number' -f /etc/config/uLinux.conf 2>/dev/null)"
printf '__QTS_BUILD_DATE__=%s\n' "$(/sbin/getcfg System 'Build Date' -f /etc/config/uLinux.conf 2>/dev/null)"
printf '__KERNEL__=%s\n' "$(uname -r)"
printf '__ARCHITECTURE__=%s\n' "$(uname -m)"
printf '__CPU_THREADS__=%s\n' "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
awk '/^MemTotal:/{printf "__MEM_TOTAL_KIB__=%s\n",$2}/^MemAvailable:/{printf "__MEM_AVAILABLE_KIB__=%s\n",$2}' /proc/meminfo
printf '__UPTIME_SECONDS__=%s\n' "$(cut -d. -f1 /proc/uptime)"
printf '__ROOT_UID__=%s\n' "$(id -u)"

echo '__DISKS_BEGIN__'
qcli_storage -d 2>&1
echo '__DISKS_END__'

echo '__STORAGE_BEGIN__'
qcli_storage -p 2>&1
echo '__STORAGE_END__'

echo '__VOLUMES_BEGIN__'
qcli_storage -v 2>&1
echo '__VOLUMES_END__'

echo '__MDSTAT_BEGIN__'
cat /proc/mdstat 2>/dev/null
echo '__MDSTAT_END__'

sed -n 's/^\[\(.*\)\]$/\1/p' /etc/config/qpkg.conf 2>/dev/null |
while IFS= read -r package; do
    version=$(/sbin/getcfg "$package" Version -f /etc/config/qpkg.conf 2>/dev/null)
    enabled=$(/sbin/getcfg "$package" Enable -f /etc/config/qpkg.conf 2>/dev/null)
    safe_package=$(printf '%s' "$package" | tr '|' '/')
    safe_version=$(printf '%s' "$version" | tr '|' '/')
    safe_enabled=$(printf '%s' "$enabled" | tr '|' '/')
    printf '__QPKG__=%s|%s|%s\n' "$safe_package" "$safe_version" "$safe_enabled"
done
'@

$remoteOutput = @(
    & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $rootHelper -Command $remoteCommand 2>&1 |
        ForEach-Object { [string]$_ }
)

function Get-TaggedValue {
    param([Parameter(Mandatory)][string]$Name)
    $prefix = "__$Name`__="
    foreach ($line in $remoteOutput) {
        if ($line.StartsWith($prefix, [StringComparison]::Ordinal)) {
            return $line.Substring($prefix.Length).Trim()
        }
    }
    ''
}

function Get-TaggedBlock {
    param([Parameter(Mandatory)][string]$Name)
    $begin = "__$Name`_BEGIN__"
    $end = "__$Name`_END__"
    $inside = $false
    $values = [Collections.Generic.List[string]]::new()
    foreach ($line in $remoteOutput) {
        if ($line -eq $begin) {
            $inside = $true
            continue
        }
        if ($line -eq $end) {
            break
        }
        if ($inside -and -not [string]::IsNullOrWhiteSpace($line)) {
            $values.Add($line.TrimEnd())
        }
    }
    @($values)
}

$diskLines = @(Get-TaggedBlock -Name 'DISKS')
$storageLines = @(Get-TaggedBlock -Name 'STORAGE')
$volumeLines = @(Get-TaggedBlock -Name 'VOLUMES')
$mdstatLines = @(Get-TaggedBlock -Name 'MDSTAT')

$disks = @(
    foreach ($line in $diskLines) {
        if ($line -match '^Enclosure\s+' -or $line -notmatch '^\S') {
            continue
        }
        if ($line -match '^(?<enclosure>\S+)\s+(?<port>\d+)\s+(?<device>/dev/\S+)\s+(?<type>\S+)\s*(?<size>\d+(?:\.\d+)?\s+[KMGT]B)\s+(?<alias>.+?)\s{2,}(?<signature>\S+(?:\s+\S+)?)\s{2,}(?<partitions>\d+)\s+(?<model>.+)$') {
            [pscustomobject]@{
                Enclosure = $Matches.enclosure
                Port = [int]$Matches.port
                Device = $Matches.device
                Type = $Matches.type
                Size = $Matches.size
                Alias = $Matches.alias
                Signature = $Matches.signature
                Partitions = $Matches.partitions
                Model = $Matches.model
            }
        }
    }
)

$volumes = @(
    foreach ($line in $volumeLines) {
        if ($line -match '^VolID\s+') {
            continue
        }
        $parts = [regex]::Split($line.Trim(), '\s{2,}', 3)
        if ($parts.Count -eq 3 -and $parts[0] -match '^\d+$') {
            [pscustomobject]@{
                Id = [int]$parts[0]
                Name = $parts[1]
                MountPath = $parts[2]
            }
        }
    }
)

$packages = @(
    foreach ($line in $remoteOutput) {
        if ($line -match '^__QPKG__=([^|]*)\|([^|]*)\|(.*)$') {
            [pscustomobject]@{
                Name = $Matches[1]
                Version = $Matches[2]
                Enabled = $Matches[3] -match '^(1|TRUE|YES)$'
            }
        }
    }
)

$failedMembers = @(@(
    foreach ($line in $mdstatLines) {
        foreach ($match in [regex]::Matches($line, '\b(sd[a-z]+\d+)\[\d+\]\(F\)')) {
            $match.Groups[1].Value
        }
    }
) | Sort-Object -Unique)

$storageIssues = @(@(
    $storageLines | Where-Object {
        $_ -match '(?i)degraded|rebuilding|migrating|/dev/sd[a-z]+\(X\)|/dev/md\d+\(!\)'
    }
) | Sort-Object -Unique)

$memTotalKib = [double](Get-TaggedValue -Name 'MEM_TOTAL_KIB')
$memAvailableKib = [double](Get-TaggedValue -Name 'MEM_AVAILABLE_KIB')
$rootUid = Get-TaggedValue -Name 'ROOT_UID'
$overallStatus = if ($failedMembers.Count -gt 0 -or $storageIssues.Count -gt 0) {
    'critical'
}
elseif ($rootUid -ne '0') {
    'warning'
}
else {
    'ok'
}

[pscustomobject]@{
    ObservedAt = (Get-Date).ToString('o')
    SystemId = 'qnap_nas'
    Hostname = Get-TaggedValue -Name 'HOSTNAME'
    Model = Get-TaggedValue -Name 'MODEL'
    InternalModel = Get-TaggedValue -Name 'INTERNAL_MODEL'
    QtsVersion = Get-TaggedValue -Name 'QTS_VERSION'
    QtsBuild = Get-TaggedValue -Name 'QTS_BUILD'
    QtsBuildDate = Get-TaggedValue -Name 'QTS_BUILD_DATE'
    Kernel = Get-TaggedValue -Name 'KERNEL'
    Architecture = Get-TaggedValue -Name 'ARCHITECTURE'
    CpuThreads = [int](Get-TaggedValue -Name 'CPU_THREADS')
    MemoryTotalMiB = [math]::Round($memTotalKib / 1024, 1)
    MemoryAvailableMiB = [math]::Round($memAvailableKib / 1024, 1)
    UptimeSeconds = [int64](Get-TaggedValue -Name 'UPTIME_SECONDS')
    RootAccess = $rootUid -eq '0'
    OverallStatus = $overallStatus
    FailedRaidMembers = @($failedMembers)
    StorageIssues = @($storageIssues)
    Disks = @($disks)
    Volumes = @($volumes)
    Packages = @($packages)
    MdStat = @($mdstatLines)
    CollectionPolicy = 'Read-only; no share traversal, serial numbers, SMART tests, scrubs, repairs, restarts, updates, or configuration changes.'
}
