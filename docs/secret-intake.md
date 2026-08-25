# Local secret intake

Passwords, API tokens, private values, TOTP seeds, recovery codes, and private
keys must never be written into this repository or pasted into chat.

## Local web interface

Run `Start-HomelabSecretUi.cmd` from the repository root. It opens
`http://127.0.0.1:8765` and accepts passwords, API keys, and Base32 or
`otpauth://totp/...` TOTP values. Every entry can be assigned to a system and
given a label, username, and encrypted note. A system may contain multiple
separate entries. Existing metadata can be edited; leaving the secret field
empty during editing preserves the encrypted value. Optional encrypted
internal and external connection addresses can be stored with each entry.
Complete HTTP and HTTPS addresses are offered as safe links in the interface.
Legacy single addresses are treated as internal connections.

The service starts as a hidden per-user Windows task whenever
CODEX-ADMIN\Admin signs in. It remains available only on this PC at
127.0.0.1; no terminal window needs to remain open. Stored values are not
revealed in the browser. An explicit copy action places a password, API key, or
current TOTP code in the Windows clipboard; the clipboard is cleared after 30
seconds if it has not changed.

The interface does not ask for the Windows password. A web form should never
receive that system credential. Instead, the already authenticated Windows
session is the access boundary and Windows DPAPI encrypts the records for that
Windows user. The encrypted files are outside Git under:

    %LOCALAPPDATA%\CodexAdmin\secret-ui

See `apps/secret-ui/README.md` for operation and security details.

## Passwords and tokens

Open PowerShell in `C:\Codex-Admin` and run:

```powershell
.\scripts\Set-HomelabSecret.ps1 -Name unifi-admin-password
```

Paste the value at the masked prompt and press Enter. Repeat with a descriptive
lowercase name such as `proxmox-root-password`, `home-assistant-token`, or
`reverse-proxy-password`. The encrypted value is stored with Windows DPAPI in
the current user's local profile, outside Git.

To intake a value already in the clipboard without showing it:

```powershell
.\scripts\Set-HomelabSecret.ps1 -Name home-assistant-token -FromClipboard
```

This form clears the clipboard immediately after storage.

## TOTP

Use the setup page's Base32 secret or complete `otpauth://totp/...` URI. Do not
send screenshots or QR codes through chat. At the masked prompt, paste either
form:

```powershell
.\scripts\Set-HomelabTotpSecret.ps1 -Name unifi-admin-totp
```

Generate a current code locally when needed:

```powershell
.\scripts\Copy-HomelabTotpCode.ps1 -Name unifi-admin-totp
```

The code is copied without being printed. If the clipboard remains unchanged,
it is cleared automatically after 30 seconds.

## What may be edited as text

It is safe to edit `inventory/services.json` for non-secret values such as URLs,
usernames, account purpose, and `credential_ref` names. Never add the actual
secret, TOTP seed, recovery code, private key, or authorization header.

Keep at least one human-controlled break-glass administrator credential and all
recovery codes outside this VM.
