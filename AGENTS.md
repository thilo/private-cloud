# AGENTS.md

Context for anyone — human or agent — changing this repo. It covers only what
the files themselves don't tell you; everything else is documented at the point
where it takes effect.

## Scope of the project

A single-user, single-node stack on a 4 GB VPS. That is a design constraint, not
an accident: multi-node orchestration, HA, secret managers, and per-service
tuning knobs that nobody sets are out of scope. When a change adds operational
surface, the bar is "does this single box need it?".

Don't add speculative configuration — no unused env vars, no "nice to have"
toggles, no options with a single caller. Build what is asked for or what is
actually used.

## Documentation convention

- **Details live where they take effect.** A mount option is explained in the
  `volumes:` block that sets it; a memory ceiling next to the `mem_limit`; a
  header policy in the `Caddyfile`; a script's behaviour in its own header
  comment. If you change a flag, update the comment beside it. The README's
  "Files" section is the map of which file to open — keep it accurate when you
  add or remove one, and don't duplicate it here.
- **The README stays high-level:** what the stack does, how to run it, and the
  properties a user cares about ("SMB3 transport encryption", "9 of 10 services
  run a read-only rootfs"). It links to the file that carries the reasoning
  rather than repeating it. Don't move explanations back into it.
- **Comments are factual and terse.** State what the setting does and why it is
  set that way — no editorializing, no value judgements, no "elegant"/"robust".
- **Committed `*.example` files use generic placeholders** (`example.com`,
  `CHANGEME`). Real domains, hosts, usernames and passwords belong only in the
  gitignored `.env` / `.env.production` / `*.setup` files.

## Deployment reality

- The production host has **no git checkout**. The repo is copied to the server
  (scp/rsync) into a deploy directory, so **whatever is in the local working
  tree at copy time is what ships** — check you're on `main` and clean before
  copying, and remember that a local branch silently decides the deployed
  content.
- Runtime secrets live **outside** the deploy directory (`/root/.env.production`
  and `/root/.env.production.setup`), so a re-copy never overwrites or exposes
  them. Every production command needs `source scripts/prod.env` first;
  otherwise Compose targets the local stack and the wrong env file.
- Compose overlays are how local and production differ. Never fork
  `docker-compose.yml` per environment.

## Testing

- `scripts/verify.sh` **cannot run unattended**: the Immich test prompts
  interactively for the admin email and password (Immich's first account is
  created in the browser and stored nowhere on disk). A run that stalls or skips
  the photo test in an automated context is not a regression.
- The local stack needs `node` and `python3` on the host for the verification
  scripts, plus a working CIFS mount — the Samba simulator exercises the same
  mount path as production, so a change to the mount options can and should be
  tested locally before it ships.

## Decisions already taken (don't re-propose)

- **Runtime secrets stay in the env file, not `/run/secrets`.** On a
  single-node, single-user stack the gain is marginal: reading a container's env
  already requires root or Docker-socket access (which grants `/run/secrets`
  too), the env file is `chmod 600` and outside the deploy dir, and several
  secrets can't be file-mounted anyway (Redis takes its password as a CLI arg,
  the Storage Box password lives in the CIFS volume options, the Seafile image
  is env-only). The worthwhile win — getting *setup* secrets out of the runtime
  container env — is already implemented via `docker-compose.setup.yml`.
- **Immich upload speed: tuning stopped at the CIFS mount options.** A
  local-first write path (staging uploads on local SSD behind a storage-template
  loopback, or a mergerfs union over the CIFS mount) was considered and
  rejected: too much moving machinery and failure surface for one user's camera
  roll.
- **Seafile sync throughput is CPU-bound, not storage-bound.** Measured: the ML
  worker competes for the two cores during a large sync. Optimising the storage
  path further won't move it.
