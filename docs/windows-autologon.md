# Optional Windows automatic logon

Automatic logon is disabled by default. It is appropriate only for a dedicated,
physically protected administration VM after an explicit credential and
physical-access security decision.

`Enable-WindowsAdminAutologon.cmd` requests the password in an elevated Windows
credential dialog, validates the local account, and stores it as the LSA private
secret `DefaultPassword`. A plaintext `Winlogon\DefaultPassword` registry value
is forbidden.

The LSA secret can still be retrieved by a local administrator. Do not enable
this feature on a workstation containing personal data or shared user sessions.

Verification requires `AutoAdminLogon=1`, the selected local account, presence
of the LSA secret, absence of the plaintext registry password, and an end-to-end
restart that returns the interactive session and required loopback services.

Rollback uses `Disable-WindowsAdminAutologon.cmd`, which clears the LSA secret,
disables automatic logon, and restores the captured pre-change Winlogon state.
Never retrieve, print, export, or replace the stored LSA secret outside the
reviewed enable/disable workflow.
