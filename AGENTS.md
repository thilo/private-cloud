# AGENTS.md

Context for anyone — human or agent — changing this repo, limited to what the
files themselves don't tell you.

## Scope

A single-user, single-node stack on a 4 GB VPS. That is a constraint, not an
accident: multi-node orchestration, HA, secret managers and tuning knobs nobody
sets are out of scope. When a change adds operational surface, the bar is "does
this one box need it?".

No speculative configuration — no unused env vars, no "nice to have" toggles, no
options with a single caller. Build what is asked for or what is actually used.

## Documentation convention

- **Details live where they take effect.** A mount option is explained in the
  `volumes:` block that sets it, a memory ceiling next to the `mem_limit`, a
  header policy in the `Caddyfile`, a script's behaviour in its own header. If
  you change a flag, update the comment beside it.
- **The README stays high-level:** what the stack does, how to run it, and the
  properties a user cares about. It links to the file carrying the reasoning
  instead of repeating it — don't move explanations back into it. Its "Files"
  section is the map of which file to open; keep it accurate, don't duplicate it
  here.
- **Comments are factual and terse** — what the setting does and why it is set
  that way. No editorializing.
- **Committed `*.example` files use placeholders** (`example.com`, `CHANGEME`).
  Real domains, hosts and passwords belong only in the gitignored `.env`,
  `.env.production` and `*.setup` files.

## Deployment reality

- The production host has **no git checkout**. The repo is copied there
  (scp/rsync), so **whatever is in the working tree at copy time is what
  ships** — be on `main` and clean before copying.
- Runtime secrets live **outside** the deploy directory (`/root/.env.production`,
  `/root/.env.production.setup`), so a re-copy never overwrites them. Every
  production command needs `source scripts/prod.env` first; without it Compose
  targets the local stack and the wrong env file.
- Overlays are how local and production differ. Never fork
  `docker-compose.yml` per environment.

## Testing

- `scripts/verify.sh` **cannot run unattended**: the Immich test prompts for the
  admin email and password (that account is created in the browser and stored
  nowhere on disk). A run that stalls there is not a regression.
- The local stack needs `node` and `python3` on the host. The Samba simulator
  exercises the same mount path as production, so mount-option changes can and
  should be tested locally before they ship.
- **Immich upload speed: tuning stopped at the CIFS mount options.** A
  local-first write path (staging uploads on local SSD behind a storage-template
  loopback, or a mergerfs union over the mount) was rejected: too much machinery
  and failure surface for one user's camera roll.
- **Seafile sync throughput is CPU-bound, not storage-bound.** Measured: the ML
  worker competes for the two cores during a large sync. Optimising the storage
  path further won't move it.
