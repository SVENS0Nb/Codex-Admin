# Contributing

1. Work from a fork or branch.
2. Keep examples site-neutral and use only RFC 5737 test addresses and
   `example.invalid` names.
3. Add or update tests for behavior changes.
4. Run `scripts/Test-CodexAdminPublicProject.ps1` before committing.
5. Never bypass a secret or privacy finding by weakening the scanner. Replace
   the fixture or explicitly document a narrowly scoped test construction.
6. Keep live-system tests outside public CI.
