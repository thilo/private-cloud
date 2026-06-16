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

Edit `.env`:

```ini
HTTP_PORT=80
HTTPS_PORT=443
CADDY_TLS=you@example.com                 # switches Caddy to Let's Encrypt
SEAFILE_DOMAIN=files.example.com
IMMICH_DOMAIN=photos.example.com
VAULTWARDEN_DOMAIN=vault.example.com
VAULTWARDEN_URL=https://vault.example.com
```

Then:

1. **DNS** – point the names at your server's public IP (A/AAAA records).
   - *Fixed IP:* set the records once.
   - *Dynamic IP:* use your router's DDNS, or run a small updater
     (e.g. `qmcgaw/ddns-updater`) — not bundled here so you can match your DNS
     provider. Caddy obtains/renews certs automatically either way.
2. **Ports** – forward TCP **80 and 443** from your router to the host. Port 80
   is needed for the Let's Encrypt HTTP challenge and for HTTP→HTTPS redirects.
3. **Firewall** – only 80/443 need to be exposed; the databases are on
   `internal:` networks with no published ports.
4. `docker compose up -d && ./scripts/bootstrap.sh`.

For a CA-DNS challenge (wildcard certs / no inbound 80) build Caddy with your
provider's DNS module and use the `tls { dns … }` directive instead.

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

## Operations

```bash
docker compose ps                                   # status
docker compose logs -f <service>                    # logs
docker compose down                                 # stop (keeps volumes/data)
docker compose pull && docker compose up -d         # update images
```

**Backups:** persistent data lives in named volumes — `seafile_data`,
`seafile_db`, `immich_upload`, `immich_db`, `vaultwarden_data`. Snapshot these
(stop the stack or use DB dumps for consistency). `.env` holds the secrets —
back it up securely and separately.

## Files

```
docker-compose.yml     all services, hardening, networks, volumes
.env.example           config template (copy → .env via scripts/init.sh)
caddy/Caddyfile        reverse proxy + automatic HTTPS
scripts/init.sh        generate .env secrets
scripts/bootstrap.sh   create the Immich admin
scripts/verify.sh      the three acceptance tests
scripts/vw-test.mjs    Bitwarden-client crypto used by the password test
```
