#!/bin/sh
# Move Immich previews off the local SSD onto the Storage Box, leaving a symlink.
#
# Immich writes both derivatives of an asset into the same directory and tells
# them apart only by filename — <id>_preview.<ext> beside <id>_thumbnail.webp —
# so no mount can separate them and Immich has no setting that splits them. The
# sizes are lopsided: a preview is far larger than a thumbnail, and the thumbnail
# is the one every grid scroll reads. This sweep therefore moves each finished
# preview to /data/previews (the Storage Box, already mounted at /data) and
# replaces it with a symlink, so the absolute path Immich recorded in
# asset_file.path keeps resolving and the DB needs no migration. Thumbnails are
# left untouched on local SSD.
#
# Writes go through the symlink rather than replacing it: Immich generates
# thumbnails with sharp's toFile(), which open()s the destination — and open()
# follows a symlink instead of unlinking it, unlike the rename() an atomic-write
# pattern would use. So a regenerated preview lands on the box on its own. A
# regeneration that does replace the link (or any preview written while this is
# not running) is simply picked up by the next sweep.
#
# Losing a preview is not data loss: they are derived files, rebuilt by Admin ->
# Jobs -> Generate Thumbnails. That is what makes the swap below safe to do on a
# mount carrying nostrictsync, and why no fsync is forced here.
#
# Deleting an asset in Immich unlinks the symlink but leaves its blob on the box,
# because unlink() never follows a symlink to its target. The sweep loop collects
# those monthly, and --reclaim runs the same pass by hand (dry unless --yes). It
# is monthly rather than per-sweep because it has to walk the box; see reclaim().
# Regenerating does NOT leak: the path in the DB is unchanged, so Immich queues no
# delete and sharp overwrites through the link.
#
# Runs as the pc-immich-preview-mover service. Pass --once for a single pass —
# that is also the one-time migration of an existing thumbs/ tree, and it is
# resumable: every step is idempotent, so a re-run finishes what was interrupted.
# Stopping the service is safe and stops new moves, but does not bring previews
# back: the symlinks already written keep pointing at the box.
set -u

SRC=/data/thumbs
DST=/data/previews
INTERVAL=300  # seconds between sweeps
# Never copy a preview that Immich may still be writing: sharp writes straight to
# the final path, so an in-flight file is a short regular file at the name we
# match. find truncates an age to whole minutes before comparing, so +1 skips
# everything younger than two minutes.
SETTLE=1
# --reclaim ignores anything younger than this. It keeps the pass off files a
# concurrent sweep is still working on — a blob is on the box for a moment before
# its symlink replaces it, and a scratch .tmp has no thumbs counterpart at all, so
# either would read as an orphan mid-move.
RECLAIM_AGE=60  # minutes
# How often the sweep loop reclaims. Deletions are the only thing that orphans a
# preview, so the leak is slow; the walk it costs is of the box itself, which is
# why this is monthly rather than part of every sweep.
RECLAIM_EVERY=43200        # minutes (30 days)
STAMP="$DST/.last-reclaim" # mtime = last scheduled run; survives restarts, which
                           # a counter would not (the watchdog bounces this container)

log() { printf '%s  pc-immich-preview-mover: %s\n' "$(date '+%F %T')" "$*"; }

# Copy to the box, verify, then swap the original for a symlink. Ordered so an
# interruption always leaves the original readable: the source file is replaced
# only after its copy is present and the right size.
move_one() {
  src="$1"
  rel="${src#$SRC/}"
  dst="$DST/$rel"
  dir="${dst%/*}"
  base="${src##*/}"
  # Scratch names carry the pid so a --once migration and the running service can
  # sweep at the same time without writing over each other's half-copied file.
  # Both clean up after themselves on every failure path; only a hard kill leaves
  # a .tmp behind, which costs a few stray bytes on the box and nothing else.
  tmp="$dir/.${base}.$$.tmp"
  link="${src%/*}/.tmplink.$$.${base}"

  mkdir -p "$dir" || { log "ERROR $rel: cannot create $dir"; return 1; }

  if ! cp "$src" "$tmp"; then
    log "ERROR $rel: copy to the box failed"
    rm -f "$tmp"
    return 1
  fi

  # A last look before the swap becomes destructive. cp already fails loudly on a
  # write error, and cache=loose means this size can come from the client's
  # attribute cache rather than the box, so treat it as a cheap sanity check on
  # the copy, not proof the bytes reached the server.
  ssize=$(stat -c %s "$src" 2>/dev/null)
  dsize=$(stat -c %s "$tmp" 2>/dev/null)
  if [ -z "$dsize" ] || [ "$ssize" != "$dsize" ]; then
    log "ERROR $rel: copy is $dsize bytes, expected $ssize -- leaving the original"
    rm -f "$tmp"
    return 1
  fi

  mv -f "$tmp" "$dst" || { log "ERROR $rel: could not rename into place"; rm -f "$tmp"; return 1; }

  # rename(2) within thumbs/ — the original is a regular file until the instant
  # it is a symlink, so a reader never sees a missing path.
  ln -sf "$dst" "$link" || { log "ERROR $rel: cannot create symlink"; return 1; }
  mv -f "$link" "$src" || { log "ERROR $rel: cannot swap in symlink"; rm -f "$link"; return 1; }

  moved_bytes=$((moved_bytes + ssize))
  return 0
}

sweep() {
  # -type f is the whole selection: an already-moved preview is a symlink, so
  # what is left as a regular file is exactly what still needs moving. No
  # timestamp bookkeeping, and nothing to redo after a restart.
  #
  # The counters live inside the braces because the pipe puts that block in a
  # subshell — totalling outside it would always report zero.
  find "$SRC" -type f -name '*_preview.*' -mmin +"$SETTLE" | {
    moved=0; failed=0; moved_bytes=0
    while IFS= read -r f; do
      if move_one "$f"; then moved=$((moved + 1)); else failed=$((failed + 1)); fi
      if [ $(( (moved + failed) % 500 )) -eq 0 ]; then
        log "progress: $moved moved, $failed failed"
      fi
    done
    [ "$moved" -gt 0 ] && log "moved $moved previews ($((moved_bytes / 1024 / 1024)) MiB) to the box"
    [ "$failed" -gt 0 ] && log "$failed previews could not be moved, will retry next sweep"
    :
  }
}

# Delete blobs on the box that nothing points at any more. A preview is live iff
# an entry still exists at the same relative path under thumbs/ — that entry IS
# the pointer Immich follows, so the filesystem answers this without reading the
# database, which keeps this script free of DB credentials and schema knowledge.
#
# Occasional and manual, never part of the sweep: the walk it needs is of the box
# itself, and listing tens of thousands of files over CIFS is minutes of
# metadata round-trips — the exact cost the 5-minute sweep is built to avoid.
#
# Anything still present under thumbs/ is kept, whether it is a symlink or a plain
# file, so a preview the sweep has copied but not yet swapped is never taken.
reclaim() {
  confirm="$1"

  [ -d "$DST" ] || { log "$DST does not exist yet, nothing to reclaim"; return 0; }

  # The one failure that would be catastrophic: thumbs/ unmounted or empty makes
  # every blob on the box look orphaned, and the pass would delete the lot.
  # Immich's own marker file is the proof the volume is really there.
  if [ ! -e "$SRC/.immich" ]; then
    log "ERROR $SRC/.immich is missing -- refusing to run against a thumbs volume that may not be mounted"
    return 1
  fi

  [ "$confirm" = yes ] || log "dry run -- rerun with --reclaim --yes to delete"

  # Only ever considers files this script would have written, so a stray file on
  # the box — the stamp below included — is never a deletion candidate.
  find "$DST" -type f -name '*_preview.*' -mmin +"$RECLAIM_AGE" | {
    n=0; kept=0; bytes=0; failed=0
    while IFS= read -r blob; do
      rel="${blob#$DST/}"
      # -L first: a symlink whose target is gone fails -e but still counts.
      if [ -L "$SRC/$rel" ] || [ -e "$SRC/$rel" ]; then
        kept=$((kept + 1))
        continue
      fi
      size=$(stat -c %s "$blob" 2>/dev/null) || size=0
      n=$((n + 1)); bytes=$((bytes + size))
      if [ "$confirm" = yes ]; then
        rm -f "$blob" || { log "ERROR could not delete $rel"; failed=$((failed + 1)); }
      else
        log "orphan: $rel ($size bytes)"
      fi
    done
    if [ "$confirm" = yes ]; then
      log "reclaimed $n orphaned previews ($((bytes / 1024 / 1024)) MiB), kept $kept"
    else
      log "$n orphaned previews ($((bytes / 1024 / 1024)) MiB), kept $kept -- nothing deleted"
    fi
    [ "$failed" -gt 0 ] && log "$failed could not be deleted"
    :
  }
}

# The scheduled half of reclaim, run from the sweep loop so the two can never
# overlap — they are the same process.
maybe_reclaim() {
  [ -d "$DST" ] || return 0
  if [ -e "$STAMP" ] && [ -z "$(find "$STAMP" -mmin +"$RECLAIM_EVERY" 2>/dev/null)" ]; then
    return 0  # not due
  fi
  # Stamped before the run, not after: a reclaim that cannot proceed (wedged
  # mount, missing marker) then waits for the next window instead of retrying —
  # and logging the same error — on every sweep for as long as it lasts.
  touch "$STAMP" 2>/dev/null
  log "scheduled reclaim"
  reclaim yes
}

case "${1:-}" in
  --reclaim)
    [ "${2:-}" = --yes ] && confirm=yes || confirm=no
    log "reconciling $DST against $SRC"
    reclaim "$confirm" || exit 1
    ;;
  --once)
    log "single pass over $SRC"
    sweep
    log "pass complete"
    ;;
  "")
    log "watching $SRC, sweeping every ${INTERVAL}s, reclaiming every $((RECLAIM_EVERY / 1440))d"
    while :; do
      sweep
      maybe_reclaim
      sleep "$INTERVAL"
    done
    ;;
  *)
    echo "usage: $0 [--once | --reclaim [--yes]]" >&2
    exit 2
    ;;
esac
