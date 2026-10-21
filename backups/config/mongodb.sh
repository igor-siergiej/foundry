#!/usr/bin/env bash
# backups/config/mongodb.sh
# Backup of the shared mongo used by tandra, jewellery-catalogue, kivo, mixtape.
# Strategy: mongodump via docker exec, --gzip, atomic per-dump dir.
#
# Restore drill: see bin/restore-drill.sh — restores newest dump into a
# throwaway mongod container and runs `db.runCommand({ dbStats: 1 })` plus a
# per-DB collection count for sanity.

set -uo pipefail

SERVICE_NAME="mongodb"
CONTAINER="mongodb"
MONGO_USER="${MONGO_ROOT_USER:?mongodb backup needs MONGO_ROOT_USER (from Dokploy env)}"
MONGO_PASS="${MONGO_ROOT_PASSWORD:?mongodb backup needs MONGO_ROOT_PASSWORD (from Dokploy env)}"
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=7

do_backup() {
  ensure_dir "$DEST"
  local stamp; stamp="$(timestamp)"
  local out="$DEST/$stamp"
  ensure_dir "$out"

  log_info "$SERVICE_NAME: dumping to $out"
  if ! docker exec -e MONGO_USER="$MONGO_USER" \
                   -e MONGO_PASS="$MONGO_PASS" \
                   "$CONTAINER" \
        mongodump \
          --username "$MONGO_USER" \
          --password "$MONGO_PASS" \
          --authenticationDatabase admin \
          --gzip \
          --out /tmp/dump; then
    log_err "$SERVICE_NAME: mongodump failed"
    rm -rf -- "$out"
    return 1
  fi

  if ! docker cp "$CONTAINER:/tmp/dump" "$out/mongodump"; then
    log_err "$SERVICE_NAME: docker cp failed"
    rm -rf -- "$out"
    return 1
  fi

  docker exec "$CONTAINER" rm -rf /tmp/dump || true

  log_info "$SERVICE_NAME: dump ok ($(du -sh "$out/mongodump" | awk '{print $1}'))"
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

  local stamp; stamp="$(basename "$latest")"
  local drill_container="mongo-drill-$stamp"
  local drill_port=27118   # throwaway, NOT 27017

  log_info "$SERVICE_NAME: drilling dump $stamp into $drill_container:$drill_port"

  if ! docker run -d --rm \
        --name "$drill_container" \
        --network none \
        -p "127.0.0.1:$drill_port:27017" \
        -e MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" \
        -e MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASS" \
        mongo:7.0 \
        >/dev/null; then
    log_err "$SERVICE_NAME: failed to start drill container"
    return 1
  fi

  if ! docker exec "$drill_container" \
        mongodump --version >/dev/null 2>&1; then
    log_err "$SERVICE_NAME: drill container missing mongodump"
    docker rm -f "$drill_container" >/dev/null
    return 1
  fi

  # Restore the dump.
  if ! docker cp "$latest/mongodump" "$drill_container:/tmp/restore"; then
    log_err "$SERVICE_NAME: drill docker cp failed"
    docker rm -f "$drill_container" >/dev/null
    return 1
  fi

  if ! docker exec -e MONGO_USER="$MONGO_USER" -e MONGO_PASS="$MONGO_PASS" \
        "$drill_container" \
        mongorestore \
          --username "$MONGO_USER" \
          --password "$MONGO_PASS" \
          --authenticationDatabase admin \
          --gzip \
          --drop \
          /tmp/restore; then
    log_err "$SERVICE_NAME: drill mongorestore failed"
    docker rm -f "$drill_container" >/dev/null
    return 1
  fi

  # Sanity query: list dbs + count collections per db.
  local summary
  summary="$(docker exec -e MONGO_USER="$MONGO_USER" -e MONGO_PASS="$MONGO_PASS" \
              "$drill_container" \
              mongosh --quiet \
                      --username "$MONGO_USER" \
                      --password "$MONGO_PASS" \
                      --authenticationDatabase admin \
                      --eval '
                        db.adminCommand({ listDatabases: 1 }).databases
                          .map(d => d.name)
                          .filter(n => !["admin","local","config"].includes(n))
                          .map(n => ({ db: n, count: db.getSiblingDB(n).getCollectionNames().length }))
                  ' 2>/dev/null || true)"

  docker rm -f "$drill_container" >/dev/null

  if [ -z "$summary" ]; then
    log_err "$SERVICE_NAME: drill sanity query returned empty"
    return 1
  fi

  log_info "$SERVICE_NAME: drill ok — dbs: $summary"
  return 0
}