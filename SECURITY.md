# Security policy

## Supported versions

Only the latest tagged release and the default branch receive security fixes.

## Reporting a vulnerability

Do not open a public issue containing credentials, internal topology, logs, or
exploit details. Use GitHub's private vulnerability reporting feature when it is
enabled for the repository owner.

## Secret boundary

The repository must never contain passwords, access tokens, private keys, TOTP
seeds, recovery codes, cookies, authorization headers, production certificates,
real host fingerprints, or encrypted DPAPI vault records. Encryption does not
make a vault record suitable for publication.

Real site configuration belongs under `%LOCALAPPDATA%\CodexAdmin\site`. The
knowledge and job databases live below `%LOCALAPPDATA%\CodexAdmin` and are not
versioned. Run `scripts/Test-CodexAdminPublicProject.ps1` before every push.

## GitHub Actions

CI uses synthetic fixtures only, receives read-only repository permissions, and
must not contain live Homelab credentials or self-hosted production runners.
