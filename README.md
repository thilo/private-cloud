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

You need: a Linux host with Docker + Compose (**4 GB RAM is enough** — see
[Resource limits](#resource-limits-fits-a-4-gb-host)), a CIFS share for the
bulk storage (e.g. a Hetzner **Storage Box** with Samba/CIFS support enabled,
in the **same location** as the server — traffic between them is free), and a
domain with three names you can point at the server.

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
runtime; it is read only during the first `up` and by `verify.sh`. See
[Secrets: setup vs runtime](#secrets-setup-vs-runtime).

The `prod.env` switch points every later command at production (base + overlay
+ `/root/.env.production`):

```bash
source scripts/prod.env          # sets COMPOSE_FILE / COMPOSE_ENV_FILES / ENV_FILE
```

**2. DNS.** Point each name at the server's public IP with an **A record**
(AAAA too if the host has IPv6). Caddy then obtains/renews Let's Encrypt certs
automatically. Deploy before DNS is ready by setting `CADDY_TLS=internal`, then
flip it to your email and `docker compose up -d caddy` once records resolve.
(For a CA-DNS challenge — wildcard certs / no inbound 80 — build Caddy with
your provider's DNS module and use the `tls { dns … }` directive instead.)

**3. Ports / firewall.** Expose TCP **80 and 443** only. Port 80 is needed for
the Let's Encrypt HTTP challenge and HTTP→HTTPS redirects. The databases sit on
`internal:` networks with no published ports.

**4. Prepare the host** (installs `cifs-utils` and `sqlite3` — the latter for
consistent Vaultwarden backups — adds swap if missing, creates the `DATA_ROOT`
subdirs, creates/validates the Storage Box subfolders, and installs + enables
the `systemd` timers for the daily backup and the mount watchdog):

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
./scripts/harden-seafile.sh      # Seahub security block + cut workers to 2 (after fresh setup)
./scripts/verify.sh              # acceptance tests

# Day-to-day afterwards (prod.env already sourced):  docker compose up -d   (web vault off, signups closed)
```

How the first Immich and Vaultwarden accounts work is described under
[Local quick start](#local-quick-start) — the flow is identical in production.

## Storage layout (cheap bulk on a Storage Box)

The big, cold blobs go on the CIFS/SMB share; the databases and the hot caches
stay on the server's local SSD.

> **Never put a database on the Storage Box.** Postgres / MariaDB / SQLite need
> low-latency POSIX locking that SMB cannot provide; they will corrupt or crawl.
> The split below keeps every database local on purpose.

| Data | Location | Volume(s) |
|------|----------|-----------|
| Immich originals (`library/`, `upload/`) | **Storage Box** (CIFS) | `immich_data` |
| Immich thumbnails / transcoded video | local SSD | `immich_thumbs`, `immich_encoded` |
| Seafile object store + config (`/shared/seafile`) | **Storage Box** (CIFS) | `seafile_box` |
| Seafile logs | local SSD | `seafile_logs` |
| All databases + Vaultwarden | local SSD | `immich_db`, `seafile_db`, `vaultwarden_data` |

Immich's whole `/data` is the CIFS mount so the upload→library move stays on
one device (no cross-device rename); `thumbs/` and `encoded-video/` are mounted
back onto local SSD so browsing stays fast.

Seafile mounts the box one level **above** its object store, at
`/shared/seafile`, on purpose: the image runs first-time setup only when
`/shared/seafile/seafile-data` is *absent*, so mounting the empty box there
lets setup build the data tree on the box — a single `docker compose up`, no
two-phase migration. The chatty per-request logs are carved back to local SSD
(`seafile_logs`); Seafile's real metadata (libraries, users, file tree) lives
in **MariaDB**, which stays local. (Seafile's config, incl.
`seahub_settings.py`, also sits on the box.)

`nobrl` in the mount options avoids CIFS byte-range-lock errors, and the CIFS
volumes are owned via the mount's `uid=`/`gid=` (so `volume-init` leaves them
alone). `seal` turns on **SMB3 transport encryption** so all host↔box traffic
is encrypted on the wire (set on every mount: the two CIFS volumes plus the
`prod-setup`/`backup`/`restore` host mounts); it requires `SB_SMB_VERS` ≥
`3.0`. Note it is **transport-only**: blobs land on the box in plaintext, so
snapshots hold plaintext and a restore needs no key. For at-rest encryption use
a Seafile **encrypted library** (true client-side E2EE) or encrypt above the
mount.

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

# Day-to-day afterwards is just:  docker compose up -d   (Vaultwarden back to API-only, signups closed)
```

The initial Seafile admin password is a **setup-only** secret and lives in a
separate `.env.setup` (not loaded at runtime) — see
[Secrets: setup vs runtime](#secrets-setup-vs-runtime). Immich and Vaultwarden
have no stored admin password: register their first accounts in the browser.

Local URLs (the `*.127.0.0.1.nip.io` names resolve to `127.0.0.1`
automatically):

| App | URL | Login |
|-----|-----|-------|
| Seafile | https://seafile.127.0.0.1.nip.io:8443 | `admin@example.com` / see `.env.setup` |
| Immich | https://immich.127.0.0.1.nip.io:8443 | register the first account — see below |
| Vaultwarden | https://vault.127.0.0.1.nip.io:8443 | register the first account — see below |

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

Your browser will warn about the certificate because Caddy uses its
**internal CA** locally. Either accept the warning, or trust the root.

**Always read the root out of the running container — never keep a copy.**
Caddy generates a new local CA whenever the `caddy_data` volume is recreated
(`down -v`, a fresh setup, a wiped `DATA_ROOT`), and every generation carries
the *same* subject name (`Caddy Local Authority - <year> ECC Root`) — only the
validity dates differ. A saved `caddy-root.crt` therefore goes stale without
looking stale: `curl` fails with `unable to get local issuer certificate`, and
a keychain entry still shows the expected name while no longer matching. Read
it live and the problem cannot arise:

```bash
# curl: read the CA live, no file on disk
curl --cacert <(docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt) \
  https://immich.127.0.0.1.nip.io:8443/api/server/ping
```

`verify.sh` sidesteps this entirely by using `curl -k`.

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
*exact* CIFS mount path production uses — only `SB_HOST` differs. The sim's
Samba requires SMB encryption, so it also proves the `seal` path works end to
end. It's pulled in automatically by the `COMPOSE_FILE` line that
`scripts/init.sh` writes to `.env`. Confirm the mounts are real CIFS and
sealed:

```bash
docker exec pc-immich-server mount | grep ' /data '
#  //172.28.0.250/backup/immich on /data type cifs (…,uid=1000,…,seal,…,nobrl,…)
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
- **Photos (iOS):** App Store → *Immich* **or** *Noodle Gallery* → server URL =
  your `https://immich.…`, log in, enable background backup of your camera roll.
  The fork keeps Immich's API, so either app works; the Gallery app is the one
  that exposes the fork-only features.
- **Vaultwarden (Bitwarden apps):** in any Bitwarden client set *Self-hosted*
  → Server URL = your `https://vault.…`, then log in. Create the first account
  during initial setup, while the setup overlay has the web vault + signups
  open (see [Local quick start](#local-quick-start)); afterwards Vaultwarden
  is API-only, so daily use is through the Bitwarden extension/apps. Enable
  2FA under Settings → Security → Two-step login (Authenticator app /
  passkey).

## Hardening

Applied to every service: `security_opt: no-new-privileges`, `cap_drop: ALL`
(plus only the capabilities an image genuinely needs), pinned images, databases
on egress-blocked `internal:` networks, and a single ingress (only Caddy
publishes ports). The unauthenticated immich-ml API sits on its own `ml`
network reachable only from immich-server, not on the shared proxy bridge. A
**read-only root filesystem** + `tmpfs` for scratch is the mechanism that
satisfies "remove dev tools / package managers": even though the stock images
still contain `apt`/`apk`, an attacker cannot install or persist anything on a
read-only, capability-stripped, no-new-privileges container.

Those scratch `tmpfs` mounts are themselves hardened: `nosuid,nodev` on every
service, plus `noexec` everywhere **except `immich-ml`** — its ML runtime
mmaps executable pages from a temp file under `/tmp` at import, so `noexec`
there kills the worker boot. `noexec` closes the last gap in the read-only
guarantee: `/tmp` was the one writable path where a dropped binary could still
be executed.

Per-image status (verified on the live stack — **9 of 10 services run a
read-only root filesystem**; the one exception (`seafile-server`) is a
stock-image limitation and keeps every other control):

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
`no-new-privileges`, pinned images, a `pids_limit`, and no published ports —
only its read-only rootfs is relaxed. Seafile additionally drops its data
daemons (`seaf-server`, `seahub`, `fileserver`) to a non-root uid; only the
bundled `my_init`/nginx master remain root, which the stock image requires. The
CIFS object-store mounts (`seafile_box`, `immich_data`) carry
`noexec,nosuid,nodev`.

At the ingress, Caddy applies a shared `(security_headers)` snippet to **all
three** sites: `Strict-Transport-Security` (HSTS, 180 days, `includeSubDomains`;
no `preload` — that commitment is opt-in), `X-Content-Type-Options: nosniff`,
`Referrer-Policy: same-origin` (so the access tokens in Seafile/Immich
share-link URLs never leak to third parties via the `Referer` header, while
same-origin requests keep the full `Referer` that Seahub's Django CSRF check
needs), and the `Server` header stripped. Caddy is the edge proxy with no
`trusted_proxies` configured, so it **ignores any client-supplied
`X-Forwarded-For`** and forwards only the real connecting IP — a forged header
cannot poison the per-client login limiters that Immich
(`IMMICH_TRUSTED_PROXIES`) and Vaultwarden (`IP_HEADER=X-Forwarded-For`) build
on.

On top of the container controls, Immich runs with these application-level
settings (all on `immich-server`):

| Setting | Effect |
|---------|--------|
| `IMMICH_VERSION` pinned | server + machine-learning don't float a moving tag; bump deliberately |
| `IMMICH_TRUSTED_PROXIES=${PROXY_SUBNET}` | Immich reads the real client IP from Caddy's `X-Forwarded-For`, so the login rate-limiter and audit logs see the client rather than the proxy |

Immich's `/api/auth/admin-sign-up` endpoint only ever creates the *first*
admin and is rejected once one exists, so it closes itself after you register.
The Immich **system settings** (version-check, machine learning, sharing,
etc.) are deliberately *not* pinned via `IMMICH_CONFIG_FILE` — they stay
editable in the admin UI; harden them there if you want.

## Photos: why the Gallery fork

The photo service runs [Noodle Gallery](https://github.com/open-noodle/gallery)
(`ghcr.io/open-noodle/gallery-server` + `-ml`) rather than upstream Immich. It is
a friendly fork that rebases onto every Immich release and keeps the same REST
API, so the official Immich iOS/Android apps, the CLI and third-party clients
all work unchanged. Everything else here is unaffected: the service names,
volumes, `IMMICH_*` environment variables, networks and Caddy route are
identical — only the two image names differ.

`IMMICH_VERSION` therefore carries the **fork's** version (`v5.2.2`), not
Immich's; each release states the upstream Immich version it is based on
(v5.2.2 = Immich 3.0.3). Read the fork's release notes before bumping, and
expect a geodata re-import — see [Resource
limits](#resource-limits-fits-a-4-gb-host).

**Going back to upstream** is the two image names plus an `IMMICH_VERSION` set
to the base Immich release. The fork-specific tables (`shared_space*`,
`album_space_*`) are inert to upstream Immich, so a plain image swap is enough
to run again; the fork also ships `scripts/revert-to-immich.sql` to drop them,
which **permanently deletes** shared spaces, user groups, pet detection,
duplicate checksums and classification categories. Back up the database first
either way, and note that upstream's schema is not downgraded — you land on the
base release (3.0.3), not an older one.

## Resource limits (fits a 4 GB host)

The stack is tuned to run on a **4 GB** machine (e.g. a Hetzner **CX22**).
Every long-running service has a `mem_limit` (a hard ceiling, not a
reservation) so no single service can balloon and OOM the host. Steady-state
usage is **≈ 1.3–1.4 GB**; the ceilings deliberately *over-subscribe* (they sum
to ~5.1 GB) because they are not all hit at once — the largest spike, the
reverse-geocoding import, lands while the ML model is still idle. A small swap
file catches rare concurrent spikes (an OOM kill becomes a slowdown);
`prod-setup.sh` adds one if missing.

**The geodata import is the sizing constraint.** It re-runs on any version bump
that ships a new `cities500` dataset — not just first boot — and it spikes
`immich-server`, not only `immich-db`: measured peak **~1.5 GB** on upstream
v3.0.2 and ~1.4 GB on the Gallery fork. Under a 1024M ceiling that import is
OOM-killed *before it finishes*, so the container restarts and re-imports
forever. The loop is easy to misread, because each cycle logs a complete,
healthy-looking boot ("Immich Server is listening") right before dying; the only
direct evidence is `docker events` showing `oom` / `die exit=137`, or
`memory.peak` in the container's cgroup. Hence the 2048M ceiling below.

| Service | `mem_limit` | Tuning |
|---------|-------------|--------|
| immich-server | 2048M | `NODE_OPTIONS=--max-old-space-size=768` (GC under the cap). 2048M (not 1024M) clears the geodata import spike above; steady state is ~800M. The spike is off-heap, so the V8 cap stays at 768M |
| immich-ml | 1024M | idle-model unload (`MODEL_TTL=300`), 1 worker, serialized inference |
| seafile-server | 640M | seahub gunicorn workers 5→2 (`scripts/harden-seafile.sh`) |
| immich-db | 768M | `shared_buffers=128M`, `effective_cache_size=384M`, `max_connections=30` — pinned so Postgres does **not** auto-tune to host RAM. 768M (not 512M) clears the one-time first-boot reverse-geocoding import, which peaks ~680M |
| seafile-db | 160M | MariaDB `innodb_buffer_pool=96M`, `performance_schema=OFF` |
| notification-server | 64M | lightweight Go websocket sidecar for real-time push; idles at ~3M, so the ceiling is pure headroom |
| caddy / vaultwarden / immich-redis / seafile-redis | 96M each | seafile-redis is a pure cache (`maxmemory 48M` + LRU); immich-redis is the BullMQ job broker, so it is **not** evicted |

> **immich-db note:** the memory flags are layered on top of the image's
> default `-c config_file=/etc/postgresql/postgresql.conf` (kept in
> `command:`) — that conf carries the VectorChord `shared_preload_libraries`,
> which must not be dropped.

After a **fresh** setup (new `seafile_data` volume), apply the Seafile config
once it's bootstrapped:

```bash
./scripts/harden-seafile.sh        # Seahub security block + workers 5→2, one restart
```

`harden-seafile.sh` adds settings the `seafile-mc` image won't take from
compose `environment:` — secure/SameSite cookies, password-strength +
login-attempt limits, 2FA availability, and forced-password/bounded-expiry
share & upload links — into `conf/seahub_settings.py`, and cuts the seahub
gunicorn workers to 2 (~430 MB; override with `SEAHUB_WORKERS=N`). It's
idempotent (re-running replaces its managed block); edit the script, not the
generated files. Two self-lockout-prone options
(`FREEZE_USER_ON_LOGIN_FAILED`, force-2FA) are left commented — enabling them
breaks the admin password→token API login that the clients and `verify.sh`
use.

To give a >4 GB host more cache, raise the `immich-db` `shared_buffers` /
`effective_cache_size` and the per-service `mem_limit`s proportionally.

## Secrets: setup vs runtime

Secrets are split into two files by lifecycle, so the credentials Compose loads
into the running stack on every `up` never include human-account passwords:

| | **Runtime** secrets | **Setup-only** secrets |
|---|---|---|
| File (local / prod) | `.env` / `/root/.env.production` | `.env.setup` / `/root/.env.production.setup` |
| Loaded by | Compose, on **every** `up` | only `init.sh`, `verify.sh`, and the **first** `up` |
| Contents | DB / Redis passwords, `SEAFILE_JWT_KEY`, `SB_PASSWORD`, `VAULTWARDEN_ADMIN_TOKEN` — machine creds the long-running containers read continuously | `SEAFILE_ADMIN_*` — used once to seed the first Seafile admin, then only to log in / run `verify.sh` (Immich + Vaultwarden admins are registered in the browser, so they have no entry) |

`scripts/init.sh` generates both (each `chmod 600`, both gitignored). The setup
file is **not** referenced by the base `docker-compose.yml`, so a normal
`docker compose up -d` never puts admin creds into a container's environment.
Seafile's first-boot seeding vars live in a small overlay,
`docker-compose.setup.yml`, applied only on the first `up`; afterwards they are
absent from `docker inspect pc-seafile`. The same overlay also flips
`SIGNUPS_ALLOWED=true` and `WEB_VAULT_ENABLED=true` on Vaultwarden for that
first `up` so you can register your account in the browser; the next plain `up`
reverts both to the hardened runtime defaults.

Once your accounts exist, the secret of record is the account itself: **store
the admin passwords in Vaultwarden.** You can keep the setup file (so
`verify.sh`'s Seafile login needs no prompt) or back it up separately and
remove it from the box — runtime is unaffected either way. Keep both files in
your offline backup; losing the runtime file means losing the DB/JWT/box
credentials.

> **Why not file-based (`/run/secrets`) for runtime secrets?** On a
> single-node, single-user stack the gain is marginal: reading a container's
> env needs root or Docker-socket access (which already grants `/run/secrets`
> too), the env file is already `chmod 600` and outside the deploy dir, and
> several secrets can't be file-mounted anyway (Redis takes its password as a
> CLI arg, `SB_PASSWORD` lives in the CIFS volume options, the Seafile image
> is env-only). The worthwhile win was getting the *setup* secrets out of the
> runtime container env, above.

## Operations

```bash
docker compose ps                                   # status
docker compose logs -f <service>                    # logs
docker compose down                                 # stop (keeps volumes/data)
docker compose pull && docker compose up -d         # update images
```

**Backups:** the **fast** volumes hold the databases + metadata — `immich_db`,
`seafile_db`, `vaultwarden_data`, `seafile_data`, `immich_thumbs`,
`immich_encoded` (in production these live under `DATA_ROOT` on the attached
volume; `seafile_logs` is on the host root disk). Snapshot the attached volume,
or dump the DBs for consistency — note Seafile is useless without its MariaDB
`seafile_db`, even though the blocks are on the box. The bulk blobs live on the
**Storage Box** (`immich_data` = photo/video originals, `seafile_box` =
Seafile's object store + config). **A live Storage Box mount is not a backup**
— enable the box's scheduled **snapshots** so a deletion or ransomware event is
recoverable. The env files hold the secrets — `.env` + `.env.setup` (local dev)
and `/root/.env.production` + `/root/.env.production.setup` (server, outside
the deploy dir); back them up securely and separately. See
[Secrets: setup vs runtime](#secrets-setup-vs-runtime).

**Automated backup (`scripts/backup.sh`):** writes *consistent* dumps of the
attached-volume state to `backup/backups/` on the Storage Box — `pg_dump`
(Immich), `mariadb-dump --single-transaction` of all three Seafile DBs, a
SQLite `.backup` of Vaultwarden plus its data folder, and Caddy's TLS material.
Each artifact is written to a `.partial` file, verified (`gzip -t`), then
atomically renamed, and a `backup-manifest.txt` (sizes + sha256) is written
last as the completion marker. It overwrites a single latest set and **relies
on the box's free, automatic snapshots for dated history** (so enable those).
The bulk blobs are already on the box and are not re-copied. `prod-setup.sh`
installs + enables the daily `systemd` timer (re-run it to refresh the unit
after an update):

```bash
systemctl list-timers pc-backup.timer        # next run (default 03:30 daily)
journalctl -u pc-backup.service -n 20         # last run
source scripts/prod.env && sudo -E ./scripts/backup.sh   # run on demand
```

**Restore (`scripts/restore.sh`):** reverses the backup — `pg_dump` reload
(drop + recreate the Immich DB), `mariadb` reload of the Seafile DBs, and
replacing the Vaultwarden / Caddy data folders (then chowning Vaultwarden back
to uid 1000). It stops only the services it touches and restarts them. Restore
is destructive, so it prompts for confirmation (or pass `--yes`); restore a
subset with `./scripts/restore.sh vaultwarden --yes`.

```bash
source scripts/prod.env
sudo -E ./scripts/restore.sh --check        # verify-only: checksums + load the
                                            # Immich dump into a scratch DB + SQLite
                                            # integrity check, WITHOUT changing anything
sudo -E ./scripts/restore.sh --yes          # restore everything
```

Run `--check` periodically to confirm the latest backup is actually restorable.

**Storage Box mount watchdog (`scripts/mount-watchdog.sh`):** the kernel CIFS
mount can wedge when the Storage Box migrates (an `STATUS_LOGON_FAILURE` loop)
— the mount dies while the app still answers, so requests `502` silently. The
Seafile and Immich healthchecks stat a path under the mount so a wedge reads as
`unhealthy`, and a host `systemd` timer runs the watchdog every 60s to restart
a wedged container (the only way to remount a Docker CIFS volume; a
per-container cooldown avoids thrashing if the box is down). `prod-setup.sh`
installs + enables the timer; events go to the journal.

```bash
journalctl -u pc-mount-watchdog.service -n 20    # recent checks / restarts
```

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
scripts/prod-setup.sh  one-time host prep (cifs-utils, sqlite3, swap, DATA_ROOT dirs, Storage Box folders, systemd timers)
scripts/backup.sh      consistent DB/Vaultwarden/Caddy backup to the Storage Box
scripts/restore.sh     restore from the Storage Box (--check verifies without changing anything)
scripts/mount-watchdog.sh  detect + remount a wedged Storage Box CIFS mount (host systemd timer)
scripts/systemd/       pc-backup.* (daily backup) + pc-mount-watchdog.* (CIFS mount watchdog)
scripts/harden-seafile.sh  Seahub security settings + worker count (idempotent, run after fresh setup)
scripts/verify.sh      the three acceptance tests
scripts/vw-test.mjs    Bitwarden-client crypto used by the password test
```
