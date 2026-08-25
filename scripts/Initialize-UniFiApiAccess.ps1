[CmdletBinding()]
param(
    [switch]$Confirmed,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$PasswordRecordId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TotpRecordId,

    [Parameter(Mandatory)]
    [uri]$ControllerBase,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$CertificateSha256,

    [ValidateSet('1m', '3m', '6m', '1y', '3y', 'never')]
    [string]$Expiration = 'never'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $Confirmed) {
    throw 'Current confirmation is required because this script creates an API credential.'
}

$store = (Resolve-Path (Join-Path $PSScriptRoot '..\apps\secret-ui\backend\SecretUiStore.ps1')).Path
$controllerBase = $ControllerBase.AbsoluteUri.TrimEnd('/')
$certificatePin = $CertificateSha256
$stage = 'initialize'
$keyId = $null
$apiKey = $null
$vaultId = $null
$committed = $false
$rollbackAttempted = $false
$rollbackSucceeded = $false
$verificationStatuses = @()
$httpStatus = $null
$remoteCode = $null
$remoteMessage = $null

function Get-VaultClipboardValue {
    param([Parameter(Mandatory)][string]$RecordId)

    & pwsh.exe -NoLogo -NoProfile -NonInteractive -File $store `
        -Action Copy -Id $RecordId -ClearAfterSeconds 5 | Out-Null
    $value = (Get-Clipboard -Raw).TrimEnd("`r", "`n")
    Set-Clipboard -Value ''
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Vault value is unavailable.'
    }
    $value
}

function New-JsonContent {
    param([Parameter(Mandatory)]$Value)

    $json = $Value | ConvertTo-Json -Compress
    try {
        [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
    }
    finally {
        $json = $null
    }
}

function Get-ExpirationUnixTime {
    param([Parameter(Mandatory)][string]$Value)

    $now = [DateTimeOffset]::UtcNow
    switch ($Value) {
        '1m' { $now.AddMonths(1).ToUnixTimeSeconds() }
        '3m' { $now.AddMonths(3).ToUnixTimeSeconds() }
        '6m' { $now.AddMonths(6).ToUnixTimeSeconds() }
        '1y' { $now.AddYears(1).ToUnixTimeSeconds() }
        '3y' { $now.AddYears(3).ToUnixTimeSeconds() }
        default { $null }
    }
}

if (-not ('CodexPinnedHttps' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

public static class CodexPinnedHttps {
    private static bool Matches(X509Certificate2 cert, string expectedSha256) {
        if (cert == null) return false;
        using (var sha = SHA256.Create()) {
            var actual = BitConverter.ToString(sha.ComputeHash(cert.RawData)).Replace("-", "");
            return String.Equals(actual, expectedSha256, StringComparison.OrdinalIgnoreCase);
        }
    }

    public static HttpClientHandler CreateHandler(string expectedSha256) {
        var handler = new HttpClientHandler();
        handler.CookieContainer = new CookieContainer();
        handler.AllowAutoRedirect = true;
        handler.ServerCertificateCustomValidationCallback = (message, cert, chain, errors) =>
            Matches(cert, expectedSha256);
        return handler;
    }

    public static int GetStatus(string host, int port, string path, string apiKey, string expectedSha256) {
        using (var tcp = new TcpClient()) {
            tcp.Connect(host, port);
            using (var ssl = new SslStream(tcp.GetStream(), false, (sender, cert, chain, errors) => {
                if (cert == null) return false;
                using (var x509 = new X509Certificate2(cert)) {
                    return Matches(x509, expectedSha256);
                }
            })) {
                ssl.AuthenticateAsClient(new SslClientAuthenticationOptions {
                    TargetHost = host,
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                });
                var request = "GET " + path + " HTTP/1.1\r\n" +
                              "Host: " + host + "\r\n" +
                              "Accept: application/json\r\n" +
                              "X-API-Key: " + apiKey + "\r\n" +
                              "Connection: close\r\n\r\n";
                var bytes = Encoding.ASCII.GetBytes(request);
                ssl.Write(bytes, 0, bytes.Length);
                ssl.Flush();
                using (var reader = new StreamReader(ssl, Encoding.ASCII, false, 1024, true)) {
                    var line = reader.ReadLine();
                    if (String.IsNullOrWhiteSpace(line)) return 0;
                    var parts = line.Split(' ');
                    int status;
                    return parts.Length > 1 && Int32.TryParse(parts[1], out status) ? status : 0;
                }
            }
        }
    }
}
'@
}

$handler = [CodexPinnedHttps]::CreateHandler($certificatePin)
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)

try {
    $stage = 'local-primary-login'
    $password = Get-VaultClipboardValue -RecordId $PasswordRecordId
    $content = New-JsonContent ([ordered]@{
        username = 'sven-beck@web.de'
        password = $password
        rememberMe = $true
    })
    $response = $client.PostAsync("$controllerBase/api/auth/login", $content).GetAwaiter().GetResult()
    $primaryStatus = [int]$response.StatusCode
    $response.Dispose()
    $content.Dispose()
    if ($primaryStatus -ne 499 -and ($primaryStatus -lt 200 -or $primaryStatus -ge 300)) {
        throw 'Primary local authentication failed.'
    }

    $stage = 'local-mfa-login'
    $totp = Get-VaultClipboardValue -RecordId $TotpRecordId
    $content = New-JsonContent ([ordered]@{
        username = 'sven-beck@web.de'
        password = $password
        token = $totp
        rememberMe = $true
    })
    $password = $null
    $totp = $null
    $response = $client.PostAsync("$controllerBase/api/auth/login", $content).GetAwaiter().GetResult()
    $mfaStatus = [int]$response.StatusCode
    $csrfValues = $null
    $hasCsrf = $response.Headers.TryGetValues('X-Csrf-Token', [ref]$csrfValues)
    $response.Dispose()
    $content.Dispose()
    if ($mfaStatus -lt 200 -or $mfaStatus -ge 300) {
        throw 'Local MFA authentication failed.'
    }
    $csrfValues = @($csrfValues)
    if (-not $hasCsrf -or $csrfValues.Count -ne 1) {
        throw 'Local MFA response did not contain one CSRF token.'
    }
    $client.DefaultRequestHeaders.TryAddWithoutValidation('X-Csrf-Token', $csrfValues[0]) | Out-Null
    $csrfValues = $null

    $stage = 'resolve-local-user'
    $response = $client.GetAsync("$controllerBase/api/users/self").GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        $response.Dispose()
        throw 'Current local user could not be resolved.'
    }
    $selfRaw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $response.Dispose()
    $self = $selfRaw | ConvertFrom-Json -Depth 20
    $selfRaw = $null
    $userId = if ($self.data.id) { [string]$self.data.id } else { [string]$self.id }
    if ([string]::IsNullOrWhiteSpace($userId)) {
        throw 'Current local user has no identifier.'
    }

    $stage = 'preflight'
    $keysForUserPath = "/proxy/users/api/v2/user/$userId/keys"
    $response = $client.GetAsync("$controllerBase$keysForUserPath").GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        $response.Dispose()
        throw 'Local API-key preflight failed.'
    }
    $existingRaw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $response.Dispose()
    $existing = $existingRaw | ConvertFrom-Json -Depth 20
    $existingRaw = $null
    if (@($existing.data | Where-Object name -eq 'Codex Admin VM').Count -gt 0) {
        throw 'A local key with the requested name already exists.'
    }

    $stage = 'create-local-key'
    $createPayload = [ordered]@{
        name = 'Codex Admin VM'
        description = 'Dedicated API access for the Codex admin VM.'
    }
    $expiresAt = Get-ExpirationUnixTime -Value $Expiration
    if ($null -ne $expiresAt) {
        $createPayload.expired_at = $expiresAt
    }
    $content = New-JsonContent $createPayload
    $response = $client.PostAsync("$controllerBase$keysForUserPath", $content).GetAwaiter().GetResult()
    $createStatus = [int]$response.StatusCode
    $httpStatus = $createStatus
    $creationRaw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $response.Dispose()
    $content.Dispose()
    if ($createStatus -lt 200 -or $createStatus -ge 300) {
        try {
            $failure = $creationRaw | ConvertFrom-Json -Depth 10
            $remoteCode = if ($failure.codeS) { [string]$failure.codeS } else { [string]$failure.code }
            $remoteMessage = if ($failure.msg) { [string]$failure.msg } else { [string]$failure.message }
        }
        catch {
            $remoteCode = 'unparseable-error'
        }
        $creationRaw = $null
        throw 'Local API-key creation failed.'
    }
    $created = $creationRaw | ConvertFrom-Json -Depth 20
    $creationRaw = $null
    $keyId = [string]$created.data.id
    $apiKey = [string]$created.data.full_api_key
    if ([string]::IsNullOrWhiteSpace($keyId) -or [string]::IsNullOrWhiteSpace($apiKey)) {
        throw 'Local API-key response was incomplete.'
    }

    $stage = 'verify-local-api'
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $infoStatus = [CodexPinnedHttps]::GetStatus(
            '192.0.2.1', 443, '/proxy/network/integration/v1/info', $apiKey, $certificatePin
        )
        $sitesStatus = [CodexPinnedHttps]::GetStatus(
            '192.0.2.1', 443, '/proxy/network/integration/v1/sites', $apiKey, $certificatePin
        )
        $verificationStatuses = @($infoStatus, $sitesStatus)
        if ($infoStatus -eq 200 -and $sitesStatus -eq 200) {
            break
        }
        if ($attempt -lt 10) {
            Start-Sleep -Seconds 2
        }
    }
    if ($infoStatus -ne 200 -or $sitesStatus -ne 200) {
        throw 'Local API-key verification failed.'
    }

    $stage = 'store-vault'
    $vaultPayload = [ordered]@{
        system = 'Unify General'
        internalEndpoint = $controllerBase
        externalEndpoint = 'https://unifi.ui.com'
        label = 'Codex Network API Key'
        username = 'Codex Admin VM'
        type = 'api_key'
        secret = $apiKey
        notes = "Dedicated console-local UniFi integration API key; owner user; expiration: $Expiration."
    } | ConvertTo-Json -Compress
    $vaultResultRaw = $vaultPayload | & pwsh.exe -NoLogo -NoProfile -NonInteractive `
        -File $store -Action Create
    $vaultPayload = $null
    $apiKey = $null
    $vaultResult = $vaultResultRaw | ConvertFrom-Json
    $vaultResultRaw = $null
    $vaultId = [string]$vaultResult.id
    if ([string]::IsNullOrWhiteSpace($vaultId)) {
        throw 'Vault storage did not return a record identifier.'
    }

    $committed = $true
    $stage = 'complete'
    [ordered]@{
        success = $true
        keyId = $keyId
        vaultRecord = $vaultId
        scope = 'console-local owner API'
        expiration = $Expiration
        infoStatus = $infoStatus
        sitesStatus = $sitesStatus
    } | ConvertTo-Json -Compress
}
catch {
    if ($keyId -and -not $committed) {
        $rollbackAttempted = $true
        try {
            $deleteResponse = $client.DeleteAsync(
                "$controllerBase/proxy/users/api/v2/keys/$keyId"
            ).GetAwaiter().GetResult()
            $rollbackSucceeded = $deleteResponse.IsSuccessStatusCode
            $deleteResponse.Dispose()
        }
        catch {
            $rollbackSucceeded = $false
        }
    }
    [ordered]@{
        success = $false
        stage = $stage
        httpStatus = $httpStatus
        remoteCode = $remoteCode
        remoteMessage = $remoteMessage
        verificationStatuses = $verificationStatuses
        remoteKeyCreated = [bool]$keyId
        rollbackAttempted = $rollbackAttempted
        rollbackSucceeded = $rollbackSucceeded
    } | ConvertTo-Json -Compress
    exit 1
}
finally {
    Set-Clipboard -Value ''
    $password = $null
    $totp = $null
    $selfRaw = $null
    $existingRaw = $null
    $creationRaw = $null
    $apiKey = $null
    $vaultPayload = $null
    $vaultResultRaw = $null
    if ($client) { $client.Dispose() }
    if ($handler) { $handler.Dispose() }
}
