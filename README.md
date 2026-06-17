# Personal Cloud

Self-hosted **Seafile** (reliable file sync with client-side encrypted libraries
— the E2EE that actually works on iOS), **Immich** (photo backup for iPhone), and
**Vaultwarden** (Bitwarden-compatible passwords with 2FA) behind a single
**Caddy** reverse proxy that serves **HTTPS for everything**. One `docker
compose`, hardened containers, runnable locally or on a real server.

```
                         ┌───────── Caddy (auto-HTTPS, only ingress) ─────────┐
  https://seafile.…    → │  seafile-server ─ seafile-db (mariadb) / -redis     │
  https://immich.…     → │  immich-server ─ immich-db / immich-redis / -ml     │
  https://vault.…      → │  vaultwarden (sqlite)                               │
                         └────────────────────────────────────────────────────┘
   databases live on internal-only networks · only Caddy publishes host ports
```

## Quick start (local test)

Requirements: Docker + Docker Compose, `node` and `python3` on the host (for the
verification scripts), outbound internet.

```bash
./scripts/init.sh          # generate .env with strong random secrets (run once)
docker compose up -d       # pull images and start everything
./scripts/bootstrap.sh     # create the Immich admin
./scripts/verify.sh        # run the three acceptance tests
```

Local URLs (the `*.127.0.0.1.nip.io` names resolve to `127.0.0.1` automatically):

| App | URL | Login |
|-----|-----|-------|
| Seafile | https://seafile.127.0.0.1.nip.io:8443 | `admin@example.com` / see `.env` |
| Immich | https://immich.127.0.0.1.nip.io:8443 | `admin@example.com` / see `.env` |
| Vaultwarden | https://vault.127.0.0.1.nip.io:8443 | register in the web vault |

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
  `https://seafile.…`, log in as `admin@example.com` (see `.env`). For E2EE,
  create an **encrypted library** (set a library password) — the password never
  leaves your device, so the server only ever stores ciphertext. The iOS app
  prompts for that password to unlock the library. This is the reliable
  encrypted file sync for the iPhone (Nextcloud's E2EE is unreliable on iOS,
  which is why this stack uses Seafile instead).
- **Immich (iOS):** App Store → Immich → server URL = your `https://immich.…`,
  log in, enable background backup of your camera roll.
- **Vaultwarden (Bitwarden apps):** in any Bitwarden client set *Self-hosted* →
  Server URL = your `https://vault.…`, then register/log in. Enable 2FA under
  Settings → Security → Two-step login (Authenticator app / passkey).

## Production deployment

Production uses a **separate env file** (`.env.production`) and a small **compose
overlay** (`docker-compose.production.yml`) that pins the latency-sensitive
volumes onto an **attached block volume** (e.g. a Hetzner Volume) while logs/temp
stay on the host root disk and the bulk blobs stay on the Storage Box. The base
`docker-compose.yml` is unchanged between local and production.

**1. Configure.** Generate `.env.production` with fresh secrets, then set your
domains, the Let's Encrypt email, the Storage Box password, and `DATA_ROOT` (a
directory on the attached volume):

```bash
ENV_FILE=.env.production EXAMPLE=.env.production.example GEN_SB_PASSWORD=0 \
  ./scripts/init.sh
$EDITOR .env.production          # set domains, CADDY_TLS, SB_PASSWORD, DATA_ROOT
```

The `prod.env` switch points every later command at production (base + overlay +
`.env.production`):

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

**5. Bring it up:**

```bash
docker compose up -d
./scripts/bootstrap.sh           # create the Immich admin
./scripts/tune-seafile.sh        # cut seahub workers to 2 (after fresh setup)
./scripts/verify.sh              # acceptance tests
```

For a CA-DNS challenge (wildcard certs / no inbound 80) build Caddy with your
provider's DNS module and use the `tls { dns … }` directive instead.

## Storage layout (cheap bulk on a Storage Box)

The big, cold blobs go on a CIFS/SMB share — a Hetzner **Storage Box** is ~10–15×
cheaper per TB than block volumes (≈ €3.20/TB vs ≈ €50/TB). The databases and the
hot caches stay on the server's local SSD, where they belong.

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
content-addressed objects — ideal for a network share. (Seafile's config, incl.
`seahub_settings.py`, also sits on the box — it travels over SMB to your own Storage
Box; enable SMB encryption if that matters to you.)

`nobrl` in the mount options avoids CIFS byte-range-lock errors, and the CIFS volumes
are owned via the mount's `uid=`/`gid=` (so `volume-init` leaves them alone).

### Test it locally first

`docker-compose.storagebox-sim.yml` runs a throwaway **Samba** container that stands
in for the Storage Box, so a local `docker compose up` exercises the *exact* CIFS
mount path production uses — only `SB_HOST` differs. It's pulled in automatically by
the `COMPOSE_FILE` line that `scripts/init.sh` writes to `.env`. Confirm the mounts
are real CIFS:

```bash
docker exec pc-immich-server mount | grep ' /data '
#  //172.28.0.250/backup/immich on /data type cifs (…,uid=1000,…,nobrl,…)
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

Per-image status (verified on the live stack — **7 of 9 services run a
read-only root filesystem**; the two exceptions are stock-image limitations and
keep every other control):

| Service | Non-root | Read-only rootfs | Notes |
|---------|----------|------------------|-------|
| caddy | root + only `NET_BIND_SERVICE` | ✅ yes | must bind 80/443 |
| vaultwarden | ✅ **uid 1000** | ✅ yes | data volume chowned by `volume-init` |
| immich-db | ✅ process drops to `postgres` | ✅ yes | minimal caps for entrypoint chown + privilege drop |
| seafile-db | ✅ process drops to `mysql` | ✅ yes | MariaDB; same minimal cap set as the Postgres tier |
| immich-redis / seafile-redis | ✅ **uid 999** | ✅ yes | ephemeral, password-protected |
| immich-server | ✅ **uid 1000 (`node`)** | ✅ yes | official image adapted to non-root; upload volume chowned |
| seafile-server | ⚠️ **daemons uid 8000** (`NON_ROOT`); init/nginx stay root | ❌ no | image regenerates config + runs its own nginx across the rootfs; `volume-init` chowns `/shared` to 8000 |
| immich-ml | root | ❌ no | ML control-server writes a socket on its rootfs |

The two ❌ services still run with `cap_drop: ALL`, `no-new-privileges`, pinned
images, and no published ports — only their read-only rootfs is relaxed. Seafile
additionally drops its data daemons (`seaf-server`, `seahub`, `fileserver`) to a
non-root uid; only the bundled `my_init`/nginx master remain root, which the
stock image requires.

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
| caddy / vaultwarden / immich-redis / seafile-redis | 96M each | seafile-redis is a pure cache (`maxmemory 48M` + LRU); immich-redis is the BullMQ job broker, so it is **not** evicted |

> **immich-db note:** the memory flags are layered on top of the image's default
> `-c config_file=/etc/postgresql/postgresql.conf` (kept in `command:`) — that conf
> carries the VectorChord `shared_preload_libraries`, which must not be dropped.

After a **fresh** setup (new `seafile_data` volume), apply the seahub worker
reduction once it's bootstrapped:

```bash
./scripts/tune-seafile.sh          # cuts seahub gunicorn workers to 2 (~430 MB)
```

To give a >4 GB host more cache, raise the `immich-db` `shared_buffers` /
`effective_cache_size` and the per-service `mem_limit`s proportionally.

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
event is recoverable. `.env` / `.env.production` hold the secrets — back them up
securely and separately.

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
scripts/verify.sh      the three acceptance tests
scripts/vw-test.mjs    Bitwarden-client crypto used by the password test
```
