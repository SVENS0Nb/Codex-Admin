[CmdletBinding()]
param(
    [ValidatePattern('^(25[0-5]|2[0-4]\d|1?\d?\d)\.(25[0-5]|2[0-4]\d|1?\d?\d)\.(25[0-5]|2[0-4]\d|1?\d?\d)$')]
    [string]$SubnetPrefix = '192.0.2',
    [int]$TimeoutMs = 350,
    [int]$ThrottleLimit = 64
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or newer is required.'
}

$ports = [ordered]@{
    22 = 'ssh'
    53 = 'dns'
    80 = 'http'
    81 = 'reverse-proxy-admin'
    443 = 'https'
    8080 = 'unifi-inform-or-http-alt'
    8006 = 'proxmox'
    8123 = 'home-assistant'
    8443 = 'unifi-legacy'
    9443 = 'https-alt'
}
$portEntries = @($ports.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{ port = [int]$_.Key; service = [string]$_.Value }
})

$results = 1..254 | ForEach-Object -Parallel {
    $ip = "$using:SubnetPrefix.$_"
    foreach ($entry in $using:portEntries) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $connect = $client.ConnectAsync($ip, $entry.port)
            if ($connect.Wait($using:TimeoutMs) -and $client.Connected) {
                [pscustomobject]@{
                    ip = $ip
                    port = $entry.port
                    service_hint = $entry.service
                }
            }
        } catch {
            # Closed, filtered, or unreachable is expected during discovery.
        } finally {
            $client.Dispose()
        }
    }
} -ThrottleLimit $ThrottleLimit

$results | Sort-Object ip, port
