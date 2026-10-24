#!/usr/bin/env bash
# backups/config/immich-pg.sh
# Backup of the immich Postgres DB. SECURITY-AUDIT #5 notes this is the only
# remaining on-host-disk exposure: uploads are on tank, but the postgres DB
# isn't, so a host-disk loss means "re-scan rebuilds the DB over hours".
# Cheap upgrade path: pg_dumpall to /mnt/tank/shared/backups/immich-pg/.
#
# Strategy: pg_dumpall via the existing immich-postgres container, gzipped.
# Note: pg_dumpall (not pg_dump) captures the user account + DBs in one file,
# which matters because the immich role is created by the immich image.

set -uo pipefail

SERVICE_NAME="immich-pg"
CONTAINER="immich-postgres"
DB_USER="${IMMICH_DB_USER:-immich}"   # matches the compose env DB_USERNAME
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=7

do_backup() {
  ensure_dir "$DEST"
  local stamp; stamp="$(timestamp)"
  local outfile="$DEST/$stamp.sql.gz"

  log_info "$SERVICE_NAME: dumping to $outfile"
  if ! docker exec "$CONTAINER" \
        pg_dumpall -U "$DB_USER" \
        | gzip -9 > "$outfile"; then
    log_err "$SERVICE_NAME: pg_dumpall failed"
    rm -f -- "$outfile"
    return 1
  fi

  log_info "$SERVICE_NAME: dump ok ($(du -sh "$outfile" | awk '{print $1}'))"
  return 0
}

do_restore_drill() {
  ensure_dir "$DEST"
  local latest
  latest="$(find "$DEST" -mindepth 1 -maxdepth 1 -type f -name '*.sql.gz' | sort -r | head -n 1)"
  if [ -z "$latest" ]; then
    log_err "$SERVICE_NAME: no dump to drill"
    return 1
  fi

  local stamp; stamp="$(basename "$latest" .sql.gz)"
  local drill_container="immich-pg-drill-$stamp"
  local drill_port=54329   # throwaway, NOT 5432

  log_info "$SERVICE_NAME: drilling dump $stamp into $drill_container:$drill_port"

  # Throwaway pg — same image as prod (postgres-vectorchord) so schema
  # features match. Restoring the dump creates the role + DB on a fresh
  # data dir, no need to set POSTGRES_DB / POSTGRES_USER.
  if ! docker run -d --rm \
        --name "$drill_container" \
        --network none \
        -p "127.0.0.1:$drill_port:5432" \
        -e POSTGRES_HOST_AUTH_METHOD=trust \
        ghcr.io/immich-app/postgres:16-vectorchord0.4.3-pgvectors0.2.0 \
        >/dev/null; then
    log_err "$SERVICE_NAME: failed to start drill container"
    return 1
  fi

  # Wait for pg to come up. Probe TCP, not the unix socket: the image's init
  # runs a temporary socket-only server first and restarts it, so a socket
  # probe passes early and the restore then hits the restart.
  for _ in {1..60}; do
    if docker exec "$drill_container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! gunzip -c "$latest" \
        | docker exec -i "$drill_container" \
            psql -U postgres -v ON_ERROR_STOP=1 \
                    -d postgres >/dev/null 2>&1; then
    log_err "$SERVICE_NAME: drill psql restore failed"
    docker rm -f "$drill_container" >/dev/null
    return 1
  fi

  local table_count
  table_count="$(docker exec "$drill_container" \
                    psql -U postgres -d immich -tA \
                    -c "select count(*) from information_schema.tables where table_schema='public';" \
                    2>/dev/null | tr -d ' \n' || echo 0)"

  docker rm -f "$drill_container" >/dev/null

  if [ -z "$table_count" ] || [ "$table_count" -lt 5 ]; then
    # immich has ~30 public tables; <5 means restore didn't really land.
    log_err "$SERVICE_NAME: drill sanity check failed (tables=$table_count, expected >5)"
    return 1
  fi

  log_info "$SERVICE_NAME: drill ok — $table_count public tables restored"
  return 0
}