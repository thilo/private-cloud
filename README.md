# Personal Cloud

Self-hosted replacements for the usual cloud subscriptions, in one
`docker compose`:

- **Seafile** — file sync (replaces Dropbox / iCloud Drive), with
  **client-side encrypted libraries** the server cannot read
- **Noodle Gallery** — automatic iPhone camera-roll backup (replaces Google /
  iCloud Photos), with ML search running locally. A rebasing fork of **Immich**
  (see [Photos: why the Gallery fork](#photos-why-the-gallery-fork))
- **Vaultwarden** — password manager with TOTP 2FA, compatible with the
  official **Bitwarden** apps and extensions

behind a single **Caddy** reverse proxy with automatic HTTPS. The same base
compose file runs locally and on a real server.


## What this stack focuses on

- **Low running cost.** Sized for a **4 GB VPS** (hard memory cap on every
  service); the bulk photo/file blobs go on a CIFS share — a Hetzner
  **Storage Box** costs ≈ €3.20/TB vs ≈ €50/TB for block volumes. Databases
  and hot caches stay on local SSD. A 1 TB setup runs under €10/month.
- **Hardened containers.** `cap_drop: ALL`, `no-new-privileges`, and pinned
  images on every service; 9 of 10 services run a **read-only root
  filesystem**, most non-root. Databases sit on egress-blocked internal
  networks, only Caddy publishes host ports, and admin passwords are kept out
  of the runtime container environment.
- **Acceptance tests against the real client APIs.** `./scripts/verify.sh`
  exercises each app end-to-end over HTTPS through the same endpoints the
  official clients use — including a small Bitwarden crypto client that
  registers an account, stores an encrypted secret, decrypts it back, and
  enables 2FA.
- **The production storage path is testable locally.** A throwaway Samba
  container stands in for the Storage Box, so a local `docker compose up`
  exercises the same CIFS mount path as production, SMB3 transport encryption
  included.
- **Scripted operations.** Daily consistent backups with a `--check` mode
  that verifies the backup is restorable, a watchdog that recovers a wedged
  CIFS mount, and a scripted restore path.

```
                         ┌───────── Caddy (auto-HTTPS, only ingress) ─────────┐
  https://seafile.…    → │  seafile-server ─ seafile-db (mariadb) / -redis     │
       …/notification  → │    └ notification-server (real-time push, ws)       │
  https://immich.…     → │  immich-server ─ immich-db / immich-redis / -ml     │
  https://vault.…      → │  vaultwarden (sqlite)                               │
                         └────────────────────────────────────────────────────┘
   databases live on internal-only networks · only Caddy publishes host ports
```

## Production deployment

You need: a Linux host with Docker + Compose (**4 GB RAM is enough**), a CIFS
share for the bulk storage (e.g. a Hetzner **Storage Box** with Samba/CIFS
support enabled, in the **same location** as the server — traffic between them
is free), and a domain with three names you can point at the server.

Production uses a **separate env file** (`.env.production`) and a small
**compose overlay** (`docker-compose.production.yml`) that pins the
latency-sensitive volumes onto an **attached block volume** (e.g. a Hetzner
Volume) while the bulk blobs go to the Storage Box. The base
`docker-compose.yml` is unchanged between local and production.

**1. Configure.** Generate `.env.production` (runtime secrets) **and**
`.env.production.setup` (the initial admin accounts), then set your domains,
the Let's Encrypt email, the Storage Box credentials (`SB_HOST` / `SB_USER` /
`SB_PASSWORD`), and `DATA_ROOT` (a directory on the attached volume):

```bash
ENV_FILE=.env.production EXAMPLE=.env.production.example GEN_SB_PASSWORD=0 \
  ./scripts/init.sh             # writes .env.production + .env.production.setup
$EDITOR .env.production          # set domains, CADDY_TLS, SB_*, DATA_ROOT
$EDITOR .env.production.setup    # set the admin email(s) to your real address
```

Then copy **both** to the server **outside the deploy directory** so rsync
updates never touch or expose them:

```bash
scp .env.production .env.production.setup root@<server>:/root/
ssh root@<server> 'chmod 600 /root/.env.production /root/.env.production.setup'
```

`.env.production.setup` is **setup-only** — Compose does not load it at
runtime. See [Secrets: setup vs runtime](#secrets-setup-vs-runtime).

The `prod.env` switch points every later command at production (base + overlay
+ `/root/.env.production`):

```bash
source scripts/prod.env          # sets COMPOSE_FILE / COMPOSE_ENV_FILES / ENV_FILE
```

**2. DNS.** Point each name at the server's public IP with an **A record**
(AAAA too if the host has IPv6). Caddy then obtains/renews Let's Encrypt certs
automatically. Deploy before DNS is ready by setting `CADDY_TLS=internal`, then
flip it to your email and `docker compose up -d caddy` once records resolve.

**3. Ports / firewall.** Expose TCP **80 and 443** only. Port 80 is needed for
the Let's Encrypt HTTP challenge and HTTP→HTTPS redirects. The databases have no
published ports.

**4. Prepare the host.** One idempotent script installs the host packages the
backups and the CIFS mount need, adds swap, creates the data directories and
Storage Box folders, and installs the `systemd` timers for the daily backup and
the mount watchdog:

```bash
sudo -E ./scripts/prod-setup.sh
```

**5. Bring it up.** The **first** `up` adds the setup overlay + setup env file
to seed the Seafile admin (and open Vaultwarden signups for first
registration); every later `up` omits both:

```bash
docker compose -f docker-compose.yml -f docker-compose.production.yml \
  -f docker-compose.setup.yml \
  --env-file /root/.env.production --env-file /root/.env.production.setup up -d
# register your Immich + Vaultwarden accounts now in a browser, while the setup overlay is up
./scripts/harden-seafile.sh      # Seahub security settings (after a fresh setup)
./scripts/verify.sh              # acceptance tests

# Day-to-day afterwards (prod.env already sourced):  docker compose up -d
```

How the first Immich and Vaultwarden accounts work is described under
[Local quick start](#local-quick-start) — the flow is identical in production.

## Storage layout

The big, cold blobs go on the CIFS/SMB share; the databases and the hot caches
stay on the server's local SSD.

> **Never put a database on the Storage Box.** Postgres / MariaDB / SQLite need
> low-latency POSIX locking that SMB cannot provide; they will corrupt or crawl.
> The split below keeps every database local on purpose.

| Data                                              | Location               | Volume(s)                                     |
| ------------------------------------------------- | ---------------------- | --------------------------------------------- |
| Immich originals (`library/`, `upload/`)          | **Storage Box** (CIFS) | `immich_data`                                 |
| Immich thumbnails / transcoded video              | local SSD              | `immich_thumbs`, `immich_encoded`             |
| Seafile object store + config (`/shared/seafile`) | **Storage Box** (CIFS) | `seafile_box`                                 |
| Seafile logs                                      | local SSD              | `seafile_logs`                                |
| All databases + Vaultwarden                       | local SSD              | `immich_db`, `seafile_db`, `vaultwarden_data` |

Seafile's real metadata — libraries, users, the file tree — lives in **MariaDB**
and stays local; only the object store and config sit on the box.

The SMB3 connection uses **transport encryption**, so all host↔box traffic is
encrypted on the wire. It is **transport-only**: blobs land on the box in
plaintext, so snapshots hold plaintext and a restore needs no key. For
encryption at rest use a Seafile **encrypted library** (true client-side E2EE)
or encrypt above the mount.

The exact mount options and the reasoning behind each one are in the `volumes:`
block of [docker-compose.yml](docker-compose.yml).

## Local quick start

Requirements: Docker + Docker Compose, `node` and `python3` on the host (for
the verification scripts), outbound internet.

```bash
./scripts/init.sh          # generate .env (runtime) + .env.setup (Seafile admin), run once

# FIRST start only — the setup overlay + setup env file seed the Seafile admin
# (and open Vaultwarden signups so you can register your first account):
docker compose -f docker-compose.yml -f docker-compose.storagebox-sim.yml \
  -f docker-compose.setup.yml --env-file .env --env-file .env.setup up -d

# register your Immich + Vaultwarden accounts now in a browser, while the setup
# overlay is up (see below)
./scripts/verify.sh        # run the three acceptance tests

# Day-to-day afterwards is just:  docker compose up -d
```

The initial Seafile admin password is a **setup-only** secret and lives in a
separate `.env.setup` (not loaded at runtime) — see
[Secrets: setup vs runtime](#secrets-setup-vs-runtime). Immich and Vaultwarden
have no stored admin password: register their first accounts in the browser.

Local URLs (the `*.127.0.0.1.nip.io` names resolve to `127.0.0.1`
automatically):

| App         | URL                                   | Login                                  |
| ----------- | ------------------------------------- | -------------------------------------- |
| Seafile     | https://seafile.127.0.0.1.nip.io:8443 | `admin@example.com` / see `.env.setup` |
| Immich      | https://immich.127.0.0.1.nip.io:8443  | register the first account — see below |
| Vaultwarden | https://vault.127.0.0.1.nip.io:8443   | register the first account — see below |

**First Immich account.** Immich's admin-sign-up page is open until the first
admin exists, then closes itself — no setup toggle needed. While the stack is
up, open the Immich URL and create your admin in the browser (nothing is
stored on disk). `verify.sh` checks whether that admin exists yet: if not, it
skips the photo test with a hint; if so, it prompts for the admin email +
password.

**First Vaultwarden account.** At runtime Vaultwarden is hardened to
**API-only**: signups closed, admin panel off, and the browser web vault
disabled (the URL 404s). The setup overlay turns the web vault + signups back
on for the first `up`: while the stack is running from that first-time command
above, open the Vaultwarden URL and register your account. The next plain
`docker compose up -d` returns it to API-only automatically. Daily use is
through a **Bitwarden browser extension or app** pointed at the same server
URL. (`verify.sh` registers through its own short-lived API toggle and cleans
up after itself.)

Your browser will warn about the certificate because Caddy uses its **internal
CA** locally. Either accept the warning, or trust the root — but **always read
the root out of the running container instead of keeping a copy**, because Caddy
silently generates a new CA whenever the `caddy_data` volume is recreated (the
[Caddyfile](caddy/Caddyfile) header explains how a saved copy goes stale without
looking stale):

```bash
# curl: read the CA live, no file on disk
curl --cacert <(docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt) \
  https://immich.127.0.0.1.nip.io:8443/api/server/ping
```

To trust it in the **macOS** system keychain, use a temp file and delete it
again. Re-run this after any CA regeneration; `add-trusted-cert` replaces the
previous entry for the same certificate:

```bash
docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > /tmp/caddy-root.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/caddy-root.crt
rm /tmp/caddy-root.crt
```

### The Storage Box simulator

`docker-compose.storagebox-sim.yml` runs a throwaway **Samba** container that
stands in for the Storage Box, so a local `docker compose up` exercises the
_exact_ CIFS mount path production uses — only `SB_HOST` differs. The sim's
Samba requires SMB encryption, so it also proves the encrypted-transport path
works end to end. It is pulled in automatically by the `COMPOSE_FILE` line that
`scripts/init.sh` writes to `.env`. Confirm the mounts are real CIFS and
encrypted:

```bash
docker exec pc-immich-server mount | grep ' /data '
docker exec pc-seafile mount | grep ' /shared/seafile '
```

## What the verification proves

`./scripts/verify.sh` exercises each app over HTTPS through Caddy:

1. **Vaultwarden** – `scripts/vw-test.mjs` is a tiny Bitwarden client (pure
   Node crypto: PBKDF2 / AES-CBC+HMAC / RSA): it registers an account, stores
   an encrypted login item, reads it back and decrypts it, and enables TOTP
   2FA.
2. **Immich** – logs in as the admin and uploads a photo through
   `POST /api/assets` (the exact endpoint the iOS app uses), then fetches the
   asset back.
3. **Seafile** – logs in via the token API, creates a library, uploads a file
   and reads back identical bytes (the same Web API the desktop/iOS clients
   use). Encrypted libraries (the client-side E2EE) are created in the app,
   not the API.

## Connecting the real clients

- **Seafile (iOS / desktop):** App Store / desktop client → server URL = your
  `https://seafile.…`, log in as `admin@example.com` (see `.env.setup`). For
  E2EE, create an **encrypted library** (set a library password) — the
  password never leaves your device, so the server only ever stores
  ciphertext. The iOS app prompts for that password to unlock the library.
- **Photos (iOS):** App Store → _Immich_ **or** _Noodle Gallery_ → server URL =
  your `https://immich.…`, log in, enable background backup of your camera roll.
  The fork keeps Immich's API, so either app works; the Gallery app is the one
  that exposes the fork-only features.
- **Vaultwarden (Bitwarden apps):** in any Bitwarden client set _Self-hosted_
  → Server URL = your `https://vault.…`, then log in. Create the first account
  during initial setup, while the setup overlay has the web vault + signups
  open (see [Local quick start](#local-quick-start)); afterwards Vaultwarden
  is API-only, so daily use is through the Bitwarden extension/apps. Enable
  2FA under Settings → Security → Two-step login (Authenticator app /
  passkey).

## Email (SMTP)

Outgoing mail is **optional and off by default** — an empty `SMTP_HOST`
disables it and all three apps run fine without it (you just get no invite,
password-reset or notification mail). One credential in the env file covers the
stack, but it reaches each app differently, because the images differ:

| App         | How it gets the config                                                  |
| ----------- | ----------------------------------------------------------------------- |
| Vaultwarden | reads `SMTP_*` directly as container env vars                           |
| Seafile     | takes **no** env vars for mail — `scripts/harden-seafile.sh` writes it   |
| Immich      | **not env-driven** — set SMTP in its web UI, stored in Immich's database |

Set the keys in `.env` / `.env.production`, then apply:

```bash
docker compose up -d vaultwarden   # Vaultwarden picks it up on recreate
./scripts/harden-seafile.sh        # writes the mail settings into Seahub, restarts Seafile
```

`harden-seafile.sh` reads whichever env file `ENV_FILE` points at (`.env`
locally, `/root/.env.production` after `source scripts/prod.env`), so the
password is written down **once**. Re-run it after any `SMTP_*` change.

## Hardening

Applied to every service: `security_opt: no-new-privileges`, `cap_drop: ALL`
(plus only the capabilities an image genuinely needs), pinned images, databases
on egress-blocked `internal:` networks, and a single ingress (only Caddy
publishes ports). The unauthenticated immich-ml API sits on its own network
reachable only from immich-server. A **read-only root filesystem** + `tmpfs` for
scratch is the mechanism that satisfies "remove dev tools / package managers":
even though the stock images still contain `apt`/`apk`, an attacker cannot
install or persist anything on a read-only, capability-stripped,
no-new-privileges container — and the scratch mounts themselves are `nosuid`,
`nodev` and (wherever the image tolerates it) `noexec`.

Verified on the live stack — **9 of 10 services run a read-only root
filesystem**; the one exception is a stock-image limitation and keeps every
other control:

| Service                      | Non-root                                                   | Read-only rootfs |
| ---------------------------- | ---------------------------------------------------------- | ---------------- |
| caddy                        | ✅ uid 1001 + only `NET_BIND_SERVICE`                      | ✅ yes           |
| vaultwarden                  | ✅ uid 1000                                                | ✅ yes           |
| immich-db                    | ✅ process drops to `postgres`                             | ✅ yes           |
| seafile-db                   | ✅ process drops to `mysql`                                | ✅ yes           |
| immich-redis / seafile-redis | ✅ uid 999                                                 | ✅ yes           |
| immich-server                | ✅ uid 1000 (`node`)                                       | ✅ yes           |
| seafile-server               | ⚠️ **daemons uid 8000** (`NON_ROOT`); init/nginx stay root | ❌ no            |
| notification-server          | ✅ uid 8000, zero capabilities                             | ✅ yes           |
| immich-ml                    | ✅ uid 1000                                                | ✅ yes           |

`seafile-server` still runs with `cap_drop: ALL`, `no-new-privileges`, pinned
images, a `pids_limit`, and no published ports — only its read-only rootfs is
relaxed, because the stock image regenerates config and runs its own nginx
across the filesystem.

At the ingress, Caddy applies a shared security-header snippet to **all three**
sites (HSTS, `nosniff`, a `Referrer-Policy` that keeps share-link tokens from
leaking to third parties, and the `Server` header stripped) and, as the edge,
ignores any client-supplied `X-Forwarded-For` — so a forged header cannot poison
the per-client login limiters in Immich and Vaultwarden. The exact directives and
their trade-offs are in [caddy/Caddyfile](caddy/Caddyfile).

Immich's `/api/auth/admin-sign-up` endpoint only ever creates the _first_ admin
and is rejected once one exists, so it closes itself after you register. Immich's
**system settings** (version-check, machine learning, sharing, etc.) are
deliberately _not_ pinned to a config file — they stay editable in the admin UI;
harden them there if you want.

## Photos: why the Gallery fork

The photo service runs [Noodle Gallery](https://github.com/open-noodle/gallery)
(`ghcr.io/open-noodle/gallery-server` + `-ml`) rather than upstream Immich. It is
a friendly fork that rebases onto every Immich release and keeps the same REST
API, so the official Immich iOS/Android apps, the CLI and third-party clients
all work unchanged. Everything else here is unaffected: the service names,
volumes, `IMMICH_*` environment variables, networks and Caddy route are
identical — only the two image names differ.

`IMMICH_VERSION` therefore carries the **fork's** version, not Immich's; each
release states the upstream Immich version it is based on. Read the fork's
release notes before bumping, and expect a geodata re-import — the boot-time
import is what sizes `immich-server`'s memory ceiling, so a version bump is the
one routine event that hits the memory budget.

## Resource footprint

The stack is tuned to run on a **4 GB** machine (e.g. a Hetzner **CX22**). Every
long-running service has a hard memory ceiling so no single service can balloon
and OOM the host; steady-state usage is **≈ 1.3–1.4 GB**. The ceilings
deliberately over-subscribe, because the peaks do not coincide, and
`prod-setup.sh` adds a swap file so a rare overlap becomes a slowdown rather
than an OOM kill. Each ceiling and the tuning that goes with it (Postgres cache
sizes, the ML model TTL, Seahub's worker count, …) is commented at the service
it applies to in [docker-compose.yml](docker-compose.yml).

After a **fresh** setup, apply the Seafile config once the server is
bootstrapped:

```bash
./scripts/harden-seafile.sh
```

It adds the settings the `seafile-mc` image won't take from compose
`environment:` — secure cookies, password-strength and login-attempt limits,
2FA availability, bounded share/upload links, outgoing mail — and cuts the
Seahub worker count to fit the memory budget. It is idempotent, so re-run it
after any change; edit the script, not the files it generates.

## Secrets: setup vs runtime

Secrets are split into two files by lifecycle, so the credentials Compose loads
into the running stack on every `up` never include human-account passwords:

|                     | **Runtime** secrets                          | **Setup-only** secrets                              |
| ------------------- | -------------------------------------------- | --------------------------------------------------- |
| File (local / prod) | `.env` / `/root/.env.production`             | `.env.setup` / `/root/.env.production.setup`        |
| Loaded by           | Compose, on **every** `up`                   | only `init.sh`, `verify.sh`, and the **first** `up` |
| Contents            | DB / Redis / Storage Box / JWT machine creds | the first Seafile admin account                     |

`scripts/init.sh` generates both (each `chmod 600`, both gitignored). The setup
file is **not** referenced by the base `docker-compose.yml`, so a normal
`docker compose up -d` never puts admin credentials into a container's
environment: Seafile's first-boot seeding vars live in a small overlay,
`docker-compose.setup.yml`, applied only on the first `up`. The same overlay
opens Vaultwarden's signups and web vault for that first `up` so you can
register your account; the next plain `up` reverts both to the hardened runtime
defaults. Immich and Vaultwarden admins are registered in the browser, so they
have no entry in either file.

Once your accounts exist, the secret of record is the account itself: **store
the admin passwords in Vaultwarden.** You can keep the setup file (so
`verify.sh`'s Seafile login needs no prompt) or back it up separately and
remove it from the box — runtime is unaffected either way. Keep both files in
your offline backup; losing the runtime file means losing the DB/JWT/box
credentials.

## Operations

```bash
docker compose ps                                   # status
docker compose logs -f <service>                    # logs
docker compose down                                 # stop (keeps volumes/data)
docker compose pull && docker compose up -d         # update images
```

**What to back up.** The **fast** volumes hold the databases + metadata (in
production they live under `DATA_ROOT` on the attached volume) — note that
Seafile is useless without its MariaDB, even though its blocks are on the box.
The bulk blobs live on the **Storage Box**, and **a live Storage Box mount is
not a backup** — enable the box's scheduled **snapshots** so a deletion or
ransomware event is recoverable. The env files hold the secrets; back them up
securely and separately. See
[Secrets: setup vs runtime](#secrets-setup-vs-runtime).

**Automated backup (`scripts/backup.sh`):** writes _consistent_ dumps of the
attached-volume state (Immich's Postgres, Seafile's three MariaDB databases,
Vaultwarden's SQLite + data folder, and Caddy's TLS material) to the Storage
Box, verifying each artifact before it replaces the previous one. It keeps a
single latest set and **relies on the box's free, automatic snapshots for dated
history** (so enable those). The bulk blobs are already on the box and are not
re-copied. `prod-setup.sh` installs + enables the daily `systemd` timer (re-run
it to refresh the unit after an update):

```bash
systemctl list-timers pc-backup.timer        # next run (default 03:30 daily)
journalctl -u pc-backup.service -n 20         # last run
source scripts/prod.env && sudo -E ./scripts/backup.sh   # run on demand
```

**Restore (`scripts/restore.sh`):** reverses the backup, stopping only the
services it touches. Restore is destructive, so it prompts for confirmation (or
pass `--yes`); restore a subset with `./scripts/restore.sh vaultwarden --yes`.

```bash
source scripts/prod.env
sudo -E ./scripts/restore.sh --check        # verify-only: checksums + a trial load
                                            # of the dumps, WITHOUT changing anything
sudo -E ./scripts/restore.sh --yes          # restore everything
```

Run `--check` periodically to confirm the latest backup is actually restorable.

**Storage Box mount watchdog (`scripts/mount-watchdog.sh`):** the kernel CIFS
mount can wedge when the Storage Box migrates — the mount dies while the app
still answers, so requests `502` silently. The Seafile and Immich healthchecks
stat a path under the mount so a wedge reads as `unhealthy`, and a host
`systemd` timer runs the watchdog every 60s to restart a wedged container.
`prod-setup.sh` installs + enables the timer; events go to the journal.

```bash
journalctl -u pc-mount-watchdog.service -n 20    # recent checks / restarts
```

## Files

```
docker-compose.yml     all services, hardening, networks, volumes
docker-compose.production.yml      production overlay: bind fast volumes to the attached volume
docker-compose.storagebox-sim.yml  local Samba server that simulates the Storage Box
docker-compose.setup.yml           first-`up` overlay: seed the Seafile admin, open signups
.env.example           local config template (copy → .env via scripts/init.sh)
.env.production.example production config template (copy → .env.production)
.env.setup.example     setup-only secrets template (initial Seafile admin)
caddy/Caddyfile        reverse proxy + automatic HTTPS
scripts/init.sh        generate env-file secrets (.env or .env.production)
scripts/prod.env       source to point compose + scripts at production
scripts/prod-setup.sh  one-time host prep (packages, swap, data dirs, Storage Box folders, systemd timers)
scripts/backup.sh      consistent DB/Vaultwarden/Caddy backup to the Storage Box
scripts/restore.sh     restore from the Storage Box (--check verifies without changing anything)
scripts/mount-watchdog.sh  detect + remount a wedged Storage Box CIFS mount (host systemd timer)
scripts/systemd/       pc-backup.* (daily backup) + pc-mount-watchdog.* (CIFS mount watchdog)
scripts/harden-seafile.sh  Seahub security settings + worker count (idempotent, run after fresh setup)
scripts/verify.sh      the three acceptance tests
scripts/vw-test.mjs    Bitwarden-client crypto used by the password test
AGENTS.md              conventions + decisions for anyone (human or agent) changing this repo
```
