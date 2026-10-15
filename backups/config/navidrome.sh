#!/usr/bin/env bash
# backups/config/navidrome.sh
# Backup of navidrome metadata DB (scan history, playlists, favourites).
# Music itself lives on tank under /mnt/tank/shared/navidrome/ — already
# on the ZFS mirror, no need to back up the FLACs.
#
# Strategy: SQLite `.backup` of navidrome.db inside the container's
# /data volume. The config is on a Docker named volume (navidrome-config),
# not a bind mount, so we go via `docker exec` rather than the host path.

set -uo pipefail

SERVICE_NAME="navidrome"
CONTAINER="navidrome"
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=7

do_backup() {
  ensure_dir "$DEST"
  local stamp; stamp="$(timestamp)"
  local staging="$DEST/$stamp"
  ensure_dir "$staging"

  if ! docker exec "$CONTAINER" \
        sqlite3 /data/navidrome.db ".backup '/data/navidrome.db.bak'"; then
    log_err "$SERVICE_NAME: sqlite .backup inside container failed"
    rm -rf -- "$staging"
    return 1
  fi

  if ! docker cp "$CONTAINER:/data/navidrome.db.bak" "$staging/navidrome.db"; then
    log_err "$SERVICE_NAME: docker cp failed"
    docker exec "$CONTAINER" rm -f /data/navidrome.db.bak || true
    rm -rf -- "$staging"
    return 1
  fi

  docker exec "$CONTAINER" rm -f /data/navidrome.db.bak || true
  log_info "$SERVICE_NAME: dump ok ($(du -sh "$staging/navidrome.db" | awk '{print $1}'))"
  return 0
}

do_restore_drill() {
  ensure_dir "$DEST"
  local latest
  latest="$(find "$DEST" -mindepth 1 -maxdepth 1 -type d | sort -r | head -n 1)"
  if [ -z "$latest" ]; then
    log_err "$SERVICE_NAME: no dump to drill"
    return 1
  fi

  local db="$latest/navidrome.db"
  local integrity rows
  integrity="$(sqlite3 "$db" "PRAGMA integrity_check;" 2>&1 | head -1)"
  rows="$(sqlite3 "$db" "select count(*) from album;" 2>/dev/null | tr -d ' \n' || echo 0)"

  if [ "$integrity" != "ok" ] || [ -z "$rows" ]; then
    log_err "$SERVICE_NAME: drill sanity failed (integrity=$integrity albums=$rows)"
    return 1
  fi

  log_info "$SERVICE_NAME: drill ok — integrity=ok albums=$rows"
  return 0
}