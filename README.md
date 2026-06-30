# Personal Cloud

Self-hosted **Seafile** (file sync with client-side encrypted libraries),
**Immich** (photo backup for iPhone), and
**Vaultwarden** (Bitwarden-compatible passwords with 2FA) behind a single
**Caddy** reverse proxy that serves **HTTPS for everything**. One `docker
compose`, hardened containers, runnable locally or on a real server.

```
                         ┌───────── Caddy (auto-HTTPS, only ingress) ─────────┐
  https://seafile.…    → │  seafile-server ─ seafile-db (mariadb) / -redis     │
       …/notification  → │    └ notification-server (real-time push, ws)       │
  https://immich.…     → │  immich-server ─ immich-db / immich-redis / -ml     │
  https://vault.…      → │  vaultwarden (sqlite)                               │
                         └────────────────────────────────────────────────────┘
   databases live on internal-only networks · only Caddy publishes host ports
```

## Quick start (local test)

Requirements: Docker + Docker Compose, `node` and `python3` on the host (for the
verification scripts), outbound internet.

```bash
./scripts/init.sh          # generate .env (runtime) + .env.setup (admin accounts), run once

# FIRST start only — the setup overlay + setup env file seed the admin accounts
# (and open Vaultwarden signups so you can register your first account):
docker compose -f docker-compose.yml -f docker-compose.storagebox-sim.yml \
  -f docker-compose.setup.yml --env-file .env --env-file .env.setup up -d

./scripts/bootstrap.sh     # create the Immich admin
# register your Vaultwarden account now in a browser, while the web vault + signups are open (see below)
./scripts/verify.sh        # run the three acceptance tests

# Day-to-day afterwards is just:  docker compose up -d   (Vaultwarden back to API-only, signups closed)
```

The initial admin passwords are **setup-only** secrets and live in a separate
`.env.setup` (not loaded at runtime) — see [Secrets: setup vs runtime](#secrets-setup-vs-runtime).

Local URLs (the `*.127.0.0.1.nip.io` names resolve to `127.0.0.1` automatically):

| App | URL | Login |
|-----|-----|-------|
| Seafile | https://seafile.127.0.0.1.nip.io:8443 | `admin@example.com` / see `.env.setup` |
| Immich | https://immich.127.0.0.1.nip.io:8443 | `admin@example.com` / see `.env.setup` |
| Vaultwarden | https://vault.127.0.0.1.nip.io:8443 | register the first account — see below |

**First Vaultwarden account.** Vaultwarden seeds no admin from env — registration
is the only path to a first account — but at runtime it is hardened to **API-only**:
signups are closed (`VAULTWARDEN_SIGNUPS_ALLOWED=false`), the admin panel is off
(`VAULTWARDEN_ADMIN_TOKEN` empty), and the browser web vault is disabled
(`WEB_VAULT_ENABLED=false`, so the URL 404s). The **setup overlay turns the web
vault and signups back on for the initial `up`** (the same overlay that seeds the
Seafile admin): while the stack is running from that first-time command above, open
https://vault.127.0.0.1.nip.io:8443 in a browser and register your account. The
next plain `docker compose up -d` omits the overlay and returns Vaultwarden to
**API-only** automatically (no web UI, signups closed) — no manual toggle needed.
For daily use after that, point a **Bitwarden browser extension or app** at the
same server URL (the API stays available). (`verify.sh` registers through its own
short-lived API toggle and cleans up after itself, so it neither needs nor leaves
an open signup window.)

Your browser will warn about the certificate because Caddy uses its **internal
CA** locally. Either accept the warning, or trust the root once:

```bash
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
# macOS: add to login keychain and trust
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt
```

## What the verification proves

`./scripts/verify.sh` exercises each app over HTTPS through Caddy:

1. **Vaultwarden** – `scripts/vw-test.mjs` is a tiny Bitwarden client (pure Node
   crypto: PBKDF2 / AES-CBC+HMAC / RSA): it registers an account, stores an
   encrypted login item, reads it back and decrypts it, and enables TOTP 2FA.
2. **Immich** – logs in as the admin and uploads a photo through `POST /api/assets`
   (the exact endpoint the iOS app uses), then fetches the asset back.
3. **Seafile** – logs in via the token API, creates a library, uploads a file and
   reads back identical bytes (the same Web API the desktop/iOS clients use).
   Encrypted libraries (the client-side E2EE) are created in the app, not the API.

## Connecting the real clients

- **Seafile (iOS / desktop):** App Store / desktop client → server URL = your
  `https://seafile.…`, log in as `admin@example.com` (see `.env.setup`). For E2EE,
  create an **encrypted library** (set a library password) — the password never
  leaves your device, so the server only ever stores ciphertext. The iOS app
  prompts for that password to unlock the library.
- **Immich (iOS):** App Store → Immich → server URL = your `https://immich.…`,
  log in, enable background backup of your camera roll.
- **Vaultwarden (Bitwarden apps):** in any Bitwarden client set *Self-hosted* →
  Server URL = your `https://vault.…`, then log in. Create the first account
  during initial setup, while the setup overlay has the web vault + signups open
  (see [First Vaultwarden account](#quick-start-local-test)); afterwards
  Vaultwarden is API-only (no browser web vault), so daily use is through the
  Bitwarden extension/apps. Enable 2FA under Settings → Security → Two-step login
  (Authenticator app / passkey).

## Production deployment

Production uses a **separate env file** (`.env.production`) and a small **compose
overlay** (`docker-compose.production.yml`) that pins the latency-sensitive
volumes onto an **attached block volume** (e.g. a Hetzner Volume) while logs/temp
stay on the host root disk and the bulk blobs stay on the Storage Box. The base
`docker-compose.yml` is unchanged between local and production.

**1. Configure.** Generate `.env.production` (runtime secrets) **and**
`.env.production.setup` (the initial admin accounts), then set your domains, the
Let's Encrypt email, the Storage Box password, and `DATA_ROOT` (a directory on the
attached volume):

```bash
ENV_FILE=.env.production EXAMPLE=.env.production.example GEN_SB_PASSWORD=0 \
  ./scripts/init.sh             # writes .env.production + .env.production.setup
$EDITOR .env.production          # set domains, CADDY_TLS, SB_PASSWORD, DATA_ROOT
$EDITOR .env.production.setup    # set the admin email(s) to your real address
```

Then copy **both** to the server **outside the deploy directory** so rsync updates
never touch or expose them:

```bash
scp .env.production .env.production.setup root@<server>:/root/
ssh root@<server> 'chmod 600 /root/.env.production /root/.env.production.setup'
```

`.env.production.setup` is **setup-only** — Compose does not load it at runtime; it
is read only during the first `up` and by `bootstrap.sh` / `verify.sh`. See
[Secrets: setup vs runtime](#secrets-setup-vs-runtime).

The `prod.env` switch points every later command at production (base + overlay +
`/root/.env.production`):

```bash
source scripts/prod.env          # sets COMPOSE_FILE / COMPOSE_ENV_FILES / ENV_FILE
```

**2. DNS.** Point each name at the server's public IP with an **A record**
(AAAA too if the host has IPv6). Caddy then obtains/renews Let's Encrypt certs
automatically. Deploy before DNS is ready by setting `CADDY_TLS=internal`, then
flip it to your email and `docker compose up -d caddy` once records resolve.

**3. Ports / firewall.** Expose TCP **80 and 443** only. Port 80 is needed for
the Let's Encrypt HTTP challenge and HTTP→HTTPS redirects. The databases sit on
`internal:` networks with no published ports.

**4. Prepare the host** (installs `cifs-utils` and `sqlite3` — the latter for
consistent Vaultwarden backups — adds swap if missing, creates the `DATA_ROOT`
subdirs, and creates/validates the Storage Box subfolders):

```bash
sudo -E ./scripts/prod-setup.sh
```

**5. Bring it up.** The **first** `up` adds the setup overlay + setup env file to
seed the Seafile admin (and open Vaultwarden signups for first registration);
every later `up` omits both:

```bash
docker compose -f docker-compose.yml -f docker-compose.production.yml \
  -f docker-compose.setup.yml \
  --env-file /root/.env.production --env-file /root/.env.production.setup up -d
./scripts/bootstrap.sh           # create the Immich admin
# register your Vaultwarden account now in a browser, while the web vault + signups are open
./scripts/tune-seafile.sh        # cut seahub workers to 2 (after fresh setup)
./scripts/verify.sh              # acceptance tests

# Day-to-day afterwards (prod.env already sourced):  docker compose up -d   (web vault off, signups closed)
```

For a CA-DNS challenge (wildcard certs / no inbound 80) build Caddy with your
provider's DNS module and use the `tls { dns … }` directive instead.

## Storage layout (cheap bulk on a Storage Box)

The big, cold blobs go on a CIFS/SMB share — a Hetzner **Storage Box** is ~10–15×
cheaper per TB than block volumes (≈ €3.20/TB vs ≈ €50/TB). The databases and the
hot caches stay on the server's local SSD.

> **Never put a database on the Storage Box.** Postgres / MariaDB / SQLite need
> low-latency POSIX locking that SMB cannot provide; they will corrupt or crawl. The
> split below keeps every database local on purpose.

| Data | Location | Volume(s) |
|------|----------|-----------|
| Immich originals (`library/`, `upload/`) | **Storage Box** (CIFS) | `immich_data` |
| Immich thumbnails / transcoded video | local SSD | `immich_thumbs`, `immich_encoded` |
| Seafile object store + config (`/shared/seafile`) | **Storage Box** (CIFS) | `seafile_box` |
| Seafile logs | local SSD | `seafile_logs` |
| All databases + Vaultwarden | local SSD | `immich_db`, `seafile_db`, `vaultwarden_data` |

Immich's whole `/data` is the CIFS mount so the upload→library move stays on one
device (no cross-device rename); `thumbs/` and `encoded-video/` are mounted back onto
local SSD so browsing stays fast.

Seafile mounts the box one level **above** its object store, at `/shared/seafile`, on
purpose: the image runs first-time setup only when `/shared/seafile/seafile-data` is
*absent*, so mounting the empty box there lets setup run and build the data tree on the
box — a single `docker compose up`, no two-phase migration. The chatty per-request logs
are carved back to local SSD (`seafile_logs`); Seafile's real metadata (libraries,
users, file tree) lives in **MariaDB**, which stays local. Blocks are immutable
content-addressed objects. (Seafile's config, incl.
`seahub_settings.py`, also sits on the box — it travels over SMB to your own Storage
Box.)

`nobrl` in the mount options avoids CIFS byte-range-lock errors, and the CIFS volumes
are owned via the mount's `uid=`/`gid=` (so `volume-init` leaves them alone). `seal`
turns on **SMB3 transport encryption** so all host↔box traffic is encrypted on the
wire (set on every mount: the two CIFS volumes plus the `prod-setup`/`backup`/`restore`
host mounts). This requires `SB_SMB_VERS` ≥ `3.0` — sealing fails on SMB 2.1. Note it
is **transport-only**: blobs are written to the box in plaintext, so snapshots hold
plaintext and a restore needs no key. For at-rest encryption use a Seafile **encrypted
library** (true client-side E2EE) or encrypt above the mount.

### Test it locally first

`docker-compose.storagebox-sim.yml` runs a throwaway **Samba** container that stands
in for the Storage Box, so a local `docker compose up` exercises the *exact* CIFS
mount path production uses — only `SB_HOST` differs. The sim's Samba is configured
with `smb encrypt = required`, so it also proves the `seal` (SMB3 encryption) path
works end to end, not just in production. It's pulled in automatically by the
`COMPOSE_FILE` line that `scripts/init.sh` writes to `.env`. Confirm the mounts are
real CIFS and sealed:

```bash
docker exec pc-immich-server mount | grep ' /data '
#  //172.28.0.250/backup/immich on /data type cifs (…,uid=1000,…,seal,…,nobrl,…)
docker exec pc-seafile mount | grep ' /shared/seafile '
```

### Switch to a real Storage Box

In production the base file's CIFS volumes already target the real box via the
`SB_*` values in `.env.production`; there is no simulator to remove (the
production overlay simply never includes `docker-compose.storagebox-sim.yml`).

1. In the Storage Box settings, **enable Samba/CIFS** support and set `SB_HOST` /
   `SB_USER` / `SB_PASSWORD` in `.env.production`.
2. The host needs `cifs-utils`, and the `immich/` and `seafile/` subfolders must
   exist on the share before first `up` (a CIFS mount of a missing subpath
   fails). Both are handled by `scripts/prod-setup.sh`; to do it by hand:
   ```bash
   sudo apt-get install -y cifs-utils
   sftp -P23 u123456@u123456.your-storagebox.de   # then:  mkdir immich   mkdir seafile
   ```
3. Put the Storage Box in the **same Hetzner location** as the server to minimise
   latency; traffic between them is free.

## Hardening

Applied to every service: `security_opt: no-new-privileges`, `cap_drop: ALL`
(plus only the capabilities an image genuinely needs), pinned images, databases
on egress-blocked `internal:` networks, and a single ingress (only Caddy
publishes ports). A **read-only root filesystem** + `tmpfs` for scratch is the
mechanism that satisfies "remove dev tools / package managers": even though the
stock images still contain `apt`/`apk`, an attacker cannot install or persist
anything on a read-only, capability-stripped, no-new-privileges container.

Those scratch `tmpfs` mounts are themselves hardened: `nosuid,nodev` on every
service, plus `noexec` everywhere **except `immich-ml`** — its ML runtime
(`onnxruntime` et al.) mmaps executable pages from a temp file under `/tmp` at
import, so `noexec` there kills the worker boot (the gunicorn master stays up but
`/ping` never answers), leaving it on `nosuid,nodev`. `noexec` closes the last gap
in the read-only guarantee: `/tmp` was the one writable path where a dropped binary
could still be executed.

Per-image status (verified on the live stack — **9 of 10 services run a
read-only root filesystem**; the one exception (`seafile-server`) is a stock-image
limitation and keeps every other control):

| Service | Non-root | Read-only rootfs | Notes |
|---------|----------|------------------|-------|
| caddy | ✅ **uid 1001** + only `NET_BIND_SERVICE` | ✅ yes | edge proxy; runs non-root (uid 1001, distinct from the uid-1000 apps) and keeps the one cap needed to bind 80/443 (the image's caddy binary carries it as a file capability); `volume-init` chowns its data/config |
| vaultwarden | ✅ **uid 1000** | ✅ yes | data volume chowned by `volume-init` |
| immich-db | ✅ process drops to `postgres` | ✅ yes | minimal caps for entrypoint chown + privilege drop |
| seafile-db | ✅ process drops to `mysql` | ✅ yes | MariaDB; same minimal cap set as the Postgres tier |
| immich-redis / seafile-redis | ✅ **uid 999** | ✅ yes | ephemeral, password-protected |
| immich-server | ✅ **uid 1000 (`node`)** | ✅ yes | official image adapted to non-root; upload volume chowned |
| seafile-server | ⚠️ **daemons uid 8000** (`NON_ROOT`); init/nginx stay root | ❌ no | image regenerates config + runs its own nginx across the rootfs; `volume-init` chowns `/shared` to 8000 |
| notification-server | ✅ **uid 8000** | ✅ yes | minimal Go websocket sidecar; its CMD is the binary directly (no `my_init`), so it runs non-root with **zero** caps — reads config from env, writes only to the (8000-owned) log volume + `/tmp` |
| immich-ml | ✅ **uid 1000** | ✅ yes | model cache chowned; `HOME` and gunicorn's control socket moved onto writable mounts (`/cache`, `/tmp`), so nothing needs the rootfs writable |

The one remaining ❌ service (`seafile-server`) still runs with `cap_drop: ALL`,
`no-new-privileges`, pinned images, a `pids_limit`, and no published ports — only
its read-only rootfs is relaxed. Seafile additionally drops its data daemons
(`seaf-server`, `seahub`, `fileserver`) to a non-root uid; only the bundled
`my_init`/nginx master remain root, which the stock image requires. The CIFS
object-store mounts (`seafile_box`, `immich_data`) carry `noexec,nosuid,nodev`.

At the ingress, Caddy applies a shared `(security_headers)` snippet to **all
three** sites: `Strict-Transport-Security` (HSTS, 180 days, `includeSubDomains`;
no `preload` — that commitment is opt-in), `X-Content-Type-Options: nosniff`,
`Referrer-Policy: same-origin` (so the access tokens in Seafile/Immich share-link
URLs never leak to third parties via the `Referer` header, while same-origin
requests keep the full `Referer` that Seahub's Django CSRF check needs), and the
`Server` header stripped. Caddy is the edge proxy with no
`trusted_proxies` configured, so it **ignores any client-supplied
`X-Forwarded-For`** and forwards only the real connecting IP — a forged header
cannot poison the per-client login limiters that Immich
(`IMMICH_TRUSTED_PROXIES`) and Vaultwarden (`IP_HEADER=X-Forwarded-For`) build on.

On top of the container controls, Immich runs with these application-level
settings (all on `immich-server`):

| Setting | Effect |
|---------|--------|
| `IMMICH_VERSION` pinned (was `release`) | server + machine-learning no longer float a moving tag; bump deliberately |
| `IMMICH_TRUSTED_PROXIES=${PROXY_SUBNET}` | Immich reads the real client IP from Caddy's `X-Forwarded-For`, so the login rate-limiter and audit logs see the client rather than the proxy |

The `/api/auth/admin-sign-up` endpoint only ever creates the *first* admin and is
rejected once one exists, so after `bootstrap.sh` runs it is already closed — no
`IMMICH_ALLOW_SETUP` flag is needed.

The Immich **system settings** (version-check, machine learning, sharing, etc.)
are deliberately *not* pinned via `IMMICH_CONFIG_FILE` — they stay editable in the
admin UI at Immich's own defaults. Harden them there
if you want (e.g. turn the GitHub version-check off for less egress).

## Resource limits (fits a 4 GB host)

The stack is tuned to run on a **4 GB** machine (e.g. a Hetzner **CX22**). Every
long-running service has a `mem_limit` (a hard ceiling, not a reservation) so no single
service can balloon and OOM the host. Steady-state usage is **≈ 1.3–1.4 GB**; the
ceilings deliberately *over-subscribe* (they sum to ~4.2 GB) because they are not all
hit at once — the largest spike, immich-db's one-time first-boot geodata import, lands
while the ML model is still idle.

> On a 4 GB host, also add a small **swap file** so a rare concurrent spike degrades to
> swap instead of an OOM kill:
> ```bash
> fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
> echo '/swapfile none swap sw 0 0' >> /etc/fstab
> ```

| Service | `mem_limit` | Tuning |
|---------|-------------|--------|
| immich-server | 1024M | `NODE_OPTIONS=--max-old-space-size=768` (GC under the cap) |
| immich-ml | 1024M | idle-model unload (`MODEL_TTL=300`), 1 worker, serialized inference |
| seafile-server | 640M | seahub gunicorn workers 5→2 (`scripts/tune-seafile.sh`) |
| immich-db | 768M | `shared_buffers=128M`, `effective_cache_size=384M`, `max_connections=30` — pinned so Postgres does **not** auto-tune to host RAM. 768M (not 512M) clears the one-time first-boot reverse-geocoding import, which peaks ~680M |
| seafile-db | 320M | MariaDB `innodb_buffer_pool=96M`, `performance_schema=OFF` |
| notification-server | 64M | lightweight Go websocket sidecar for real-time push; idles at ~3M, so the ceiling is pure headroom |
| caddy / vaultwarden / immich-redis / seafile-redis | 96M each | seafile-redis is a pure cache (`maxmemory 48M` + LRU); immich-redis is the BullMQ job broker, so it is **not** evicted |

> **immich-db note:** the memory flags are layered on top of the image's default
> `-c config_file=/etc/postgresql/postgresql.conf` (kept in `command:`) — that conf
> carries the VectorChord `shared_preload_libraries`, which must not be dropped.

After a **fresh** setup (new `seafile_data` volume), apply the seahub worker
reduction once it's bootstrapped:

```bash
./scripts/tune-seafile.sh          # cuts seahub gunicorn workers to 2 (~430 MB)
./scripts/harden-seafile.sh        # writes the Seahub security block + restarts
```

`harden-seafile.sh` adds settings the `seafile-mc` image won't take from compose
`environment:` — secure/SameSite cookies, password-strength + login-attempt limits,
2FA availability, and forced-password/bounded-expiry share & upload links — into
`conf/seahub_settings.py`. It's idempotent (re-running replaces its managed block);
edit the script, not the generated file. Two self-lockout-prone options
(`FREEZE_USER_ON_LOGIN_FAILED`, force-2FA) are left commented — enabling them breaks
the admin password→token API login that the clients and `verify.sh` use.

To give a >4 GB host more cache, raise the `immich-db` `shared_buffers` /
`effective_cache_size` and the per-service `mem_limit`s proportionally.

## Secrets: setup vs runtime

Secrets are split into two files by lifecycle, so the credentials Compose loads
into the running stack on every `up` never include human-account passwords:

| | **Runtime** secrets | **Setup-only** secrets |
|---|---|---|
| File (local / prod) | `.env` / `/root/.env.production` | `.env.setup` / `/root/.env.production.setup` |
| Loaded by | Compose, on **every** `up` | only `init.sh`, `bootstrap.sh`, `verify.sh`, and the **first** `up` |
| Contents | DB / Redis passwords, `SEAFILE_JWT_KEY`, `SB_PASSWORD`, `VAULTWARDEN_ADMIN_TOKEN` — machine creds the long-running containers read continuously | `IMMICH_ADMIN_*`, `SEAFILE_ADMIN_*` — used once to create the first admin accounts, then only to log in / run `verify.sh` |

`scripts/init.sh` generates both (each `chmod 600`, both gitignored). The setup file
is **not** referenced by the base `docker-compose.yml`, so a normal `docker compose
up -d` never puts admin creds into a container's environment. Seafile's first-boot
seeding vars (`INIT_SEAFILE_ADMIN_*`, `INIT_SEAFILE_MYSQL_ROOT_PASSWORD`) live in a
small overlay, `docker-compose.setup.yml`, applied only on the first `up`; afterwards
they are absent from `docker inspect pc-seafile`. (Immich's admin creds were never in
a container env — only `bootstrap.sh` reads them via the setup file.) The same overlay
also flips `SIGNUPS_ALLOWED=true` and `WEB_VAULT_ENABLED=true` on Vaultwarden for that
first `up` so you can register your account in the browser; the next plain `up` reverts
both to the hardened runtime defaults (signups closed, API-only).

Once your accounts exist, the secret of record is the account itself: **store the
admin passwords in Vaultwarden.** You can keep the setup file (so `verify.sh` runs
unattended), or back it up separately and remove it from the box — runtime is
unaffected either way. Keep both files in your offline backup; losing the runtime
file means losing the DB/JWT/box credentials.

> **Why not file-based (`/run/secrets`) for runtime secrets?** On a single-node,
> single-user stack the gain is marginal and uneven: reading a container's env needs
> root or Docker-socket access (which already grants `/run/secrets` too), the env file
> is already `chmod 600` and outside the deploy dir, and several secrets can't be
> file-mounted cleanly anyway (Redis takes its password as a CLI arg, `SB_PASSWORD`
> lives in the CIFS volume options, the Seafile image is env-only). There are also no
> build-time secrets — every service is a pulled image. So runtime secrets stay as
> env vars; the worthwhile win was getting the *setup* secrets out of the runtime
> container env, above.

**Migrating an existing deployment:** create `/root/.env.production.setup` with the
five `*_ADMIN_*` lines, remove them from `/root/.env.production`, then run a plain
`docker compose up -d` — it recreates `seafile-server` with a clean, admin-free env.

## Operations

```bash
docker compose ps                                   # status
docker compose logs -f <service>                    # logs
docker compose down                                 # stop (keeps volumes/data)
docker compose pull && docker compose up -d         # update images
```

**Backups:** the **fast** volumes hold the databases + metadata — `immich_db`,
`seafile_db`, `vaultwarden_data`, `seafile_data`, `immich_thumbs`, `immich_encoded`
(in production these live under `DATA_ROOT` on the attached volume; `seafile_logs` is
on the host root disk). Snapshot the attached volume, or dump the DBs for consistency —
note Seafile is useless without its MariaDB `seafile_db`, even though the blocks are on
the box. The bulk blobs live on the **Storage Box** (`immich_data` = photo/video
originals, `seafile_box` = Seafile's object store + config). **A live Storage Box mount
is not a backup** — enable the box's scheduled **snapshots** so a deletion or ransomware
event is recoverable. The env files hold the secrets — `.env` + `.env.setup` (local
dev) and `/root/.env.production` + `/root/.env.production.setup` (server, outside the
deploy dir); back them up securely and separately. See
[Secrets: setup vs runtime](#secrets-setup-vs-runtime).

**Automated backup (`scripts/backup.sh`):** writes *consistent* dumps of the
attached-volume state to `backup/backups/` on the Storage Box — `pg_dump`
(Immich), `mariadb-dump --single-transaction` of all three Seafile DBs, a SQLite
`.backup` of Vaultwarden plus its data folder, and Caddy's TLS material. Each
artifact is written to a `.partial` file, verified (`gzip -t`), then atomically
renamed, and a `backup-manifest.txt` (sizes + sha256) is written last as the
completion marker. It overwrites a single latest set and **relies on the box's
free, automatic snapshots for dated history** (so enable those). The bulk blobs
are already on the box and are not re-copied. A daily `systemd` timer runs it:

```bash
# one-time install on the server (run once):
cp scripts/systemd/pc-backup.* /etc/systemd/system/ && systemctl daemon-reload
systemctl enable --now pc-backup.timer
systemctl list-timers pc-backup.timer        # next run (default 03:30 daily)
journalctl -u pc-backup.service -n 20         # last run
source scripts/prod.env && sudo -E ./scripts/backup.sh   # run on demand
```

**Restore (`scripts/restore.sh`):** reverses the backup — `pg_dump` reload (drop
+ recreate the Immich DB), `mariadb` reload of the Seafile DBs, and replacing the
Vaultwarden / Caddy data folders (then chowning Vaultwarden back to uid 1000). It
stops only the services it touches and restarts them. Restore is destructive, so
it prompts for confirmation (or pass `--yes`); restore a subset with
`./scripts/restore.sh vaultwarden --yes`.

```bash
source scripts/prod.env
sudo -E ./scripts/restore.sh --check        # verify-only: checksums + load the
                                            # Immich dump into a scratch DB + SQLite
                                            # integrity check, WITHOUT changing anything
sudo -E ./scripts/restore.sh --yes          # restore everything
```

Run `--check` periodically to confirm the latest backup is actually restorable.

## Files

```
docker-compose.yml     all services, hardening, networks, volumes
docker-compose.production.yml      production overlay: bind fast volumes to the attached volume
docker-compose.storagebox-sim.yml  local Samba server that simulates the Storage Box
.env.example           local config template (copy → .env via scripts/init.sh)
.env.production.example production config template (copy → .env.production)
caddy/Caddyfile        reverse proxy + automatic HTTPS
scripts/init.sh        generate env-file secrets (.env or .env.production)
scripts/prod.env       source to point compose + scripts at production
scripts/prod-setup.sh  one-time host prep (cifs-utils, sqlite3, swap, DATA_ROOT dirs, Storage Box folders)
scripts/backup.sh      consistent DB/Vaultwarden/Caddy backup to the Storage Box
scripts/restore.sh     restore from the Storage Box (--check verifies without changing anything)
scripts/systemd/       pc-backup.service + .timer (daily backup)
scripts/bootstrap.sh   create the Immich admin
scripts/tune-seafile.sh  cut seahub gunicorn workers to fit 4 GB (run after fresh setup)
scripts/harden-seafile.sh  write Seahub security settings to seahub_settings.py (idempotent)
scripts/verify.sh      the three acceptance tests
scripts/vw-test.mjs    Bitwarden-client crypto used by the password test
```
