[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Enable', 'Disable')]
    [string]$Mode = 'Enable',

    [string]$AccountName,

    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$accountName = if ([string]::IsNullOrWhiteSpace($AccountName)) {
    ([Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1]
} else {
    $AccountName
}
$computerName = $env:COMPUTERNAME
$qualifiedUser = "$computerName\$accountName"
$winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$policyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$stateRoot = Join-Path $env:ProgramData 'CodexAdmin\autologon'
$backupPath = Join-Path $stateRoot 'pre-autologon-state.json'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run from an elevated Windows administrator session.'
}

if (-not ('CodexAdmin.AutologonNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace CodexAdmin {
    public static class AutologonNative {
        [StructLayout(LayoutKind.Sequential)]
        private struct LSA_OBJECT_ATTRIBUTES {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LSA_UNICODE_STRING {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool LogonUserW(
            string username,
            string domain,
            IntPtr password,
            int logonType,
            int logonProvider,
            out IntPtr token);

        [DllImport("advapi32.dll")]
        private static extern uint LsaOpenPolicy(
            IntPtr systemName,
            ref LSA_OBJECT_ATTRIBUTES objectAttributes,
            uint desiredAccess,
            out IntPtr policyHandle);

        [DllImport("advapi32.dll")]
        private static extern uint LsaStorePrivateData(
            IntPtr policyHandle,
            ref LSA_UNICODE_STRING keyName,
            IntPtr privateData);

        [DllImport("advapi32.dll")]
        private static extern uint LsaRetrievePrivateData(
            IntPtr policyHandle,
            ref LSA_UNICODE_STRING keyName,
            out IntPtr privateData);

        [DllImport("advapi32.dll")]
        private static extern uint LsaNtStatusToWinError(uint status);

        [DllImport("advapi32.dll")]
        private static extern uint LsaClose(IntPtr policyHandle);

        [DllImport("advapi32.dll")]
        private static extern uint LsaFreeMemory(IntPtr buffer);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private static LSA_OBJECT_ATTRIBUTES NewObjectAttributes() {
            LSA_OBJECT_ATTRIBUTES attributes = new LSA_OBJECT_ATTRIBUTES();
            // LsaOpenPolicy does not use these fields. Microsoft documents that
            // every member, including Length, must be initialized to zero.
            attributes.Length = 0;
            return attributes;
        }

        private static LSA_UNICODE_STRING NewUnicodeString(string value, out IntPtr allocatedBuffer) {
            allocatedBuffer = Marshal.StringToHGlobalUni(value);
            return new LSA_UNICODE_STRING {
                Buffer = allocatedBuffer,
                Length = checked((ushort)(value.Length * 2)),
                MaximumLength = checked((ushort)((value.Length + 1) * 2))
            };
        }

        public static void VerifyLocalCredential(string username, string domain, IntPtr password) {
            IntPtr token;
            if (!LogonUserW(username, domain, password, 2, 0, out token)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "The supplied Windows credential was not accepted.");
            }
            CloseHandle(token);
        }

        public static void SetDefaultPassword(IntPtr password, int characterCount) {
            const uint POLICY_CREATE_SECRET = 0x00000020;
            LSA_OBJECT_ATTRIBUTES attributes = NewObjectAttributes();
            IntPtr policy;
            uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, POLICY_CREATE_SECRET, out policy);
            if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));

            IntPtr nameBuffer = IntPtr.Zero;
            IntPtr dataBuffer = IntPtr.Zero;
            try {
                LSA_UNICODE_STRING name = NewUnicodeString("DefaultPassword", out nameBuffer);
                LSA_UNICODE_STRING data = new LSA_UNICODE_STRING {
                    Buffer = password,
                    Length = checked((ushort)(characterCount * 2)),
                    MaximumLength = checked((ushort)((characterCount + 1) * 2))
                };
                dataBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING)));
                Marshal.StructureToPtr(data, dataBuffer, false);
                status = LsaStorePrivateData(policy, ref name, dataBuffer);
                if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
            }
            finally {
                if (dataBuffer != IntPtr.Zero) Marshal.FreeHGlobal(dataBuffer);
                if (nameBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nameBuffer);
                LsaClose(policy);
            }
        }

        public static void ClearDefaultPassword() {
            const uint POLICY_CREATE_SECRET = 0x00000020;
            LSA_OBJECT_ATTRIBUTES attributes = NewObjectAttributes();
            IntPtr policy;
            uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, POLICY_CREATE_SECRET, out policy);
            if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));

            IntPtr nameBuffer = IntPtr.Zero;
            try {
                LSA_UNICODE_STRING name = NewUnicodeString("DefaultPassword", out nameBuffer);
                status = LsaStorePrivateData(policy, ref name, IntPtr.Zero);
                if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));
            }
            finally {
                if (nameBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nameBuffer);
                LsaClose(policy);
            }
        }

        public static bool HasDefaultPassword() {
            const uint POLICY_GET_PRIVATE_INFORMATION = 0x00000004;
            LSA_OBJECT_ATTRIBUTES attributes = NewObjectAttributes();
            IntPtr policy;
            uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, POLICY_GET_PRIVATE_INFORMATION, out policy);
            if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status));

            IntPtr nameBuffer = IntPtr.Zero;
            IntPtr privateData = IntPtr.Zero;
            try {
                LSA_UNICODE_STRING name = NewUnicodeString("DefaultPassword", out nameBuffer);
                status = LsaRetrievePrivateData(policy, ref name, out privateData);
                if (status != 0) return false;
                LSA_UNICODE_STRING data = (LSA_UNICODE_STRING)Marshal.PtrToStructure(privateData, typeof(LSA_UNICODE_STRING));
                return data.Length > 0 && data.Buffer != IntPtr.Zero;
            }
            finally {
                if (privateData != IntPtr.Zero) LsaFreeMemory(privateData);
                if (nameBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nameBuffer);
                LsaClose(policy);
            }
        }
    }
}
'@
}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @([Security.Principal.WindowsIdentity]::GetCurrent().Name, 'NT AUTHORITY\SYSTEM')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-RegistryValueState {
    param([string]$Path, [string]$Name)

    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    $property = if ($item) { $item.PSObject.Properties[$Name] } else { $null }
    [ordered]@{
        present = ($null -ne $property)
        value = if ($property) { [string]$property.Value } else { $null }
    }
}

function Restore-RegistryValueState {
    param([string]$Path, [string]$Name, $State)

    if ($State.present) {
        Ensure-RegistryKey -Path $Path
        New-ItemProperty -Path $Path -Name $Name -Value ([string]$State.value) -PropertyType String -Force | Out-Null
    }
    else {
        Remove-RegistryValueIfPresent -Path $Path -Name $Name
    }
}

function Ensure-RegistryKey {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

function Remove-RegistryValueIfPresent {
    param([string]$Path, [string]$Name)

    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($key -and $key.GetValueNames() -contains $Name) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    }
}

function Write-Result {
    param($Result)

    if ($ResultPath) {
        $Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8
    }
    $Result
}

if ($Mode -eq 'Disable') {
    if (-not $PSCmdlet.ShouldProcess($qualifiedUser, 'Disable Windows automatic logon and clear its LSA secret')) {
        return
    }

    [CodexAdmin.AutologonNative]::ClearDefaultPassword()
    New-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -Value '0' -PropertyType String -Force | Out-Null
    Remove-RegistryValueIfPresent -Path $winlogonPath -Name DefaultPassword

    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        Restore-RegistryValueState -Path $winlogonPath -Name DefaultUserName -State $backup.defaultUserName
        Restore-RegistryValueState -Path $winlogonPath -Name DefaultDomainName -State $backup.defaultDomainName
        Restore-RegistryValueState -Path $winlogonPath -Name AutoLogonCount -State $backup.autoLogonCount
        Restore-RegistryValueState -Path $policyPath -Name LegalNoticeCaption -State $backup.legalNoticeCaption
        Restore-RegistryValueState -Path $policyPath -Name LegalNoticeText -State $backup.legalNoticeText
    }

    $result = [ordered]@{
        success = $true
        mode = 'disabled'
        user = $qualifiedUser
        autoAdminLogon = '0'
        lsaSecretPresent = [CodexAdmin.AutologonNative]::HasDefaultPassword()
        completedAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-Result -Result $result
    return
}

if (-not $PSCmdlet.ShouldProcess($qualifiedUser, 'Enable Windows automatic logon with an LSA-protected password')) {
    return
}

$plaintextPasswordState = Get-RegistryValueState -Path $winlogonPath -Name DefaultPassword
if ($plaintextPasswordState.present) {
    throw 'A plaintext Winlogon DefaultPassword value already exists. Remove it through a reviewed recovery step before enabling LSA-backed autologon.'
}

Set-PrivateDirectoryAcl -Path $stateRoot
$backup = [ordered]@{
    schemaVersion = 1
    capturedAt = [DateTimeOffset]::Now.ToString('o')
    autoAdminLogon = Get-RegistryValueState -Path $winlogonPath -Name AutoAdminLogon
    defaultUserName = Get-RegistryValueState -Path $winlogonPath -Name DefaultUserName
    defaultDomainName = Get-RegistryValueState -Path $winlogonPath -Name DefaultDomainName
    autoLogonCount = Get-RegistryValueState -Path $winlogonPath -Name AutoLogonCount
    legalNoticeCaption = Get-RegistryValueState -Path $policyPath -Name LegalNoticeCaption
    legalNoticeText = Get-RegistryValueState -Path $policyPath -Name LegalNoticeText
}
$backup | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding utf8

$credential = Get-Credential -UserName $qualifiedUser -Message "Windows automatic logon: enter the current password for $qualifiedUser."
if (-not $credential) {
    throw 'Credential entry was cancelled.'
}
if ($credential.UserName -notin @($accountName, $qualifiedUser, ".\$accountName")) {
    throw "The credential must belong to $qualifiedUser."
}

$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
$secretStored = $false
try {
    [CodexAdmin.AutologonNative]::VerifyLocalCredential($accountName, $computerName, $passwordPointer)
    [CodexAdmin.AutologonNative]::SetDefaultPassword($passwordPointer, $credential.Password.Length)
    $secretStored = $true

    Ensure-RegistryKey -Path $winlogonPath
    Ensure-RegistryKey -Path $policyPath
    New-ItemProperty -Path $winlogonPath -Name DefaultUserName -Value $accountName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonPath -Name DefaultDomainName -Value $computerName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -Value '1' -PropertyType String -Force | Out-Null
    Remove-RegistryValueIfPresent -Path $winlogonPath -Name AutoLogonCount
    Remove-RegistryValueIfPresent -Path $winlogonPath -Name DefaultPassword
    Remove-RegistryValueIfPresent -Path $policyPath -Name LegalNoticeCaption
    Remove-RegistryValueIfPresent -Path $policyPath -Name LegalNoticeText

    $verified = Get-ItemProperty -Path $winlogonPath
    $result = [ordered]@{
        success = ([string]$verified.AutoAdminLogon -eq '1') -and [CodexAdmin.AutologonNative]::HasDefaultPassword()
        mode = 'enabled'
        user = "$([string]$verified.DefaultDomainName)\$([string]$verified.DefaultUserName)"
        autoAdminLogon = [string]$verified.AutoAdminLogon
        lsaSecretPresent = [CodexAdmin.AutologonNative]::HasDefaultPassword()
        plaintextDefaultPasswordPresent = ($null -ne $verified.PSObject.Properties['DefaultPassword'])
        logonBannerPresent = ($null -ne (Get-ItemProperty -Path $policyPath).PSObject.Properties['LegalNoticeCaption']) -or ($null -ne (Get-ItemProperty -Path $policyPath).PSObject.Properties['LegalNoticeText'])
        completedAt = [DateTimeOffset]::Now.ToString('o')
    }
    if (-not $result.success -or $result.plaintextDefaultPasswordPresent -or $result.logonBannerPresent) {
        throw 'Post-change verification of the LSA-backed autologon configuration failed.'
    }
    Write-Result -Result $result
}
catch {
    $originalError = $_
    if ($secretStored) {
        try { [CodexAdmin.AutologonNative]::ClearDefaultPassword() } catch { }
    }
    foreach ($restore in @(
        @{ Path = $winlogonPath; Name = 'AutoAdminLogon'; State = $backup.autoAdminLogon },
        @{ Path = $winlogonPath; Name = 'DefaultUserName'; State = $backup.defaultUserName },
        @{ Path = $winlogonPath; Name = 'DefaultDomainName'; State = $backup.defaultDomainName },
        @{ Path = $winlogonPath; Name = 'AutoLogonCount'; State = $backup.autoLogonCount },
        @{ Path = $policyPath; Name = 'LegalNoticeCaption'; State = $backup.legalNoticeCaption },
        @{ Path = $policyPath; Name = 'LegalNoticeText'; State = $backup.legalNoticeText }
    )) {
        try {
            Restore-RegistryValueState -Path $restore.Path -Name $restore.Name -State $restore.State
        }
        catch { }
    }
    throw $originalError
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
    $credential = $null
}
