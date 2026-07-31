# Changelog

Versions follow [semantic versioning](https://semver.org/);
This repo versions the orchestration (compose files, `Caddyfile`, scripts, docs) only.

## [1.0.1] — 2026-07-31

### Changed

- Gallery `v5.2.2` → `v5.2.3` (same Immich 3.0.3 base, so no geodata re-import).
- Vaultwarden `1.36.0-alpine` → `1.37.1-alpine` — required for clients 2026.7.0+,
  and carries the security fixes from the 1.37.0 advisories.
- Seafile `13.0-latest` → `13.0.25` and notification-server `13.0-latest` →
  `13.0.21`: both were floating tags in a block that claims pinning. Their patch
  numbers do not track each other; `13.0.21` is what `13.0-latest` resolved to.

### Fixed

- Quoted `SMTP_FROM_NAME` in the env templates. `backup.sh`, `restore.sh` and
  `prod-setup.sh` shell-`source` the env file, so the unquoted `Private Cloud`
  ran `Cloud` as a command and aborted them at exit 127.

## [1.0.0] — 2026-07-30

Initial release.

### Stack

- Seafile (file sync, MariaDB + Valkey, real-time notification server), Noodle
  Gallery (Immich fork: server + ML, Postgres + Valkey) and Vaultwarden behind a
  single Caddy reverse proxy with automatic HTTPS.
- One base `docker-compose.yml` for every environment; local and production
  differ only through overlays (`docker-compose.production.yml`,
  `docker-compose.storagebox-sim.yml`, `docker-compose.setup.yml`).
- Pinned images: Gallery `v5.2.2`, Vaultwarden `1.36.0-alpine`, Seafile
  `13.0-latest`, Caddy `2-alpine`, MariaDB `10.11`, Valkey `8-alpine`, Immich's
  Postgres by digest.

### Storage

- Bulk blobs (Immich originals, Seafile object store) on a CIFS Storage Box;
  databases, thumbnails and caches on local SSD.
- SMB3 transport encryption (sealing) plus `nostrictsync` on the mount.
- `docker-compose.storagebox-sim.yml` runs a throwaway Samba container so the
  production mount path is exercised locally.

### Hardening

- `no-new-privileges` and `cap_drop: ALL` on every service, with only the
  capabilities each image needs; read-only root filesystem on 9 of 10 services,
  most running non-root.
- Databases and immich-ml on egress-blocked internal networks; only Caddy
  publishes host ports.
- Shared Caddy security headers (HSTS, `nosniff`, `Referrer-Policy`, `Server`
  stripped) and client-supplied `X-Forwarded-For` ignored at the edge.
- Setup-only secrets separated from runtime secrets: the first Seafile admin is
  seeded from `docker-compose.setup.yml` and never enters the runtime container
  environment. Vaultwarden runs API-only (web vault and signups off) outside the
  setup overlay.
- `scripts/harden-seafile.sh` applies the Seahub settings the image won't take
  from compose — secure cookies, password and login-attempt policy, 2FA, bounded
  share links, outgoing mail.

### Operations

- `scripts/init.sh` generates the runtime and setup env files with fresh
  secrets; `scripts/prod-setup.sh` prepares the host (packages, swap,
  directories, systemd timers); `scripts/prod.env` points compose and scripts at
  production.
- `scripts/backup.sh` writes verified, consistent dumps to the Storage Box on a
  daily timer; `scripts/restore.sh` restores them and has a non-destructive
  `--check` mode.
- `scripts/mount-watchdog.sh` restarts a container whose CIFS mount has wedged,
  driven by storage-aware healthchecks on a 60s timer.
- `scripts/verify.sh` runs acceptance tests against the real client APIs,
  including a Bitwarden crypto client (`scripts/vw-test.mjs`) that registers an
  account, stores and decrypts an item and enables TOTP 2FA.

### Other

- Optional SMTP configuration for outgoing mail, off by default.
- Memory ceilings on every long-running service, sized for a 4 GB host.
- MIT license and `README.md`.
