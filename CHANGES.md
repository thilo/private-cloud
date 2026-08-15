# Changelog

Versions follow [semantic versioning](https://semver.org/);
This repo versions the orchestration (compose files, `Caddyfile`, scripts, docs) only.

## [1.2.4] — 2026-08-15

### Fixed

- `mount-watchdog.sh` now stops and starts the containers together instead of one at
  a time. Both mounts share one connection to the box, and the kernel keeps that
  connection alive while any container still holds it, so a container restarted on
  its own came back to the same broken connection. Its cooldown, attempt count and
  `OnFailure=` alert are now per incident rather than per container.

## [1.2.3] — 2026-08-14

### Fixed

- Both Storage Box volumes pass `addr=${SB_HOST}`, which stops Docker's local
  volume driver from replacing the hostname in `device:` with an IP. The mount
  keeps the hostname, so the kernel can resolve the box's current address when it
  reconnects.

## [1.2.2] — 2026-08-13

### Fixed

- `mount-watchdog.sh` skipped any container that was not running, so one whose
  CIFS volume failed to mount was never retried. It now starts those too; a
  container stopped by hand has no `State.Error` and is still left alone.
- `mount-watchdog.sh` mails through `OnFailure=` after three failed recovery
  attempts, once per incident. It previously exited 0 always, so no alert could
  fire.

## [1.2.1] — 2026-08-11

### Changed

- `security_headers` also removes `Via`, which named the proxy on every
  response.
- `CADDY_IMAGE` pins an exact Caddy version instead of the floating `2-alpine`
  tag, matching how the other images are pinned.

## [1.2.0] — 2026-08-11

### Added

- `prod-setup.sh` pins `docker-ce` and `containerd.io` to the majors named by
  the new `DOCKER_MAJOR`/`CONTAINERD_MAJOR` env values, and allows the Docker
  repo in `unattended-upgrades`. The engine was previously never patched
  automatically; a new major still never arrives unattended.
- `pc-docker-major-check.timer` (Mondays 06:00) mails when a `docker-ce` major
  above the pin exists. Docker patches only the current major, so the pin would
  otherwise become a silent freeze.

### Changed

- `prod-setup.sh` writes `live-restore` into `/etc/docker/daemon.json` and
  merges that file with `jq` instead of leaving it untouched when present.
  Daemon upgrades no longer bounce the stack, and re-running the script applies
  the setting without clobbering keys it does not own.

## [1.1.3] — 2026-08-08

### Changed

- `immich-ml` and `immich-server` divide the CPU by relative weight
  (`cpu_shares`) instead of fixed `cpus:` quotas. `immich-ml` keeps its previous
  share while `immich-server` is busy, but is no longer throttled against CPU
  nothing else is using.

## [1.1.2] — 2026-08-06

### Changed

- `prod-setup.sh` selects the zswap `zsmalloc` pool and the `lzo-rle`
  compressor instead of the kernel defaults `zbud`/`lzo`, and puts all three
  zswap settings on the kernel cmdline via
  `/etc/default/grub.d/99-private-cloud.cfg`. They are module parameters, so a
  runtime write alone reverts on reboot.

## [1.1.1] — 2026-08-05

### Changed

- Gallery `v5.2.3` → `v5.3.0` (Immich 3.0.3 → 3.1.0 base).
- `immich-ml` `mem_limit` `1024m` → `1280m`. Face detection, CLIP, OCR and object
  detection load as a burst when a job wakes the idle container, and that burst
  reached the old ceiling.

## [1.1.0] — 2026-08-01

### Added

- Weekly restore check: `pc-restore-check.timer` (Sundays 05:00) runs the
  existing `restore.sh --check`, so a backup that exists but does not restore is
  caught within a week instead of at the moment it is needed. It skips itself
  when `DATA_ROOT` has under 6 GB free — the scratch load needs room for a
  transient copy of the Immich DB, plus recycled WAL.
- Failed-timer email alerts: `OnFailure=` on `pc-backup.service` and
  `pc-restore-check.service` starts `pc-notify-failure@.service`, which mails the
  unit's status and journal tail with `curl` (no MTA on the host). Off unless
  both `SMTP_HOST` and the new `ALERT_EMAIL` are set — the same switch the rest
  of the mail config uses. Not wired to `pc-mount-watchdog`, whose 60s timer
  would mail on every failed check.
- `verify.sh` now checks the env files for values that `source` and Compose
  would read differently — unquoted whitespace, or `$`/backticks the shell
  expands — and refuses to run until they are quoted.
- `TimeoutStartSec=1800` on `pc-backup.service` and `pc-restore-check.service`;
  `Type=oneshot` defaults to no start timeout, so a wedged CIFS mount could hang
  a unit indefinitely.

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
