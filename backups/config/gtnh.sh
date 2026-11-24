#!/usr/bin/env bash
# backups/config/gtnh.sh
# Back up the active GTNH world and supporting state to the ZFS mirror.
# Disable world autosaves while archiving; always re-enable them on exit.

set -uo pipefail

SERVICE_NAME="gtnh"
CONTAINER="gtnh"
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=7
GTNH_WORLD="OmniSlop"

do_backup() (
  ensure_dir "$DEST"
  local stamp; stamp="$(timestamp)"
  local archive="$DEST/$stamp.tar.gz"

  if ! docker exec "$CONTAINER" rcon-cli save-off; then
    log_err "$SERVICE_NAME: could not disable autosaving"
    return 1
  fi
  trap '
    status=$?
    if ! docker exec "$CONTAINER" rcon-cli save-on; then
      log_err "$SERVICE_NAME: could not re-enable autosaving"
      status=1
    fi
    if [ "$status" -ne 0 ]; then rm -f -- "$archive"; fi
    exit "$status"
  ' EXIT
  if ! docker exec "$CONTAINER" rcon-cli save-all flush; then
    log_err "$SERVICE_NAME: could not flush world"
    return 1
  fi

  log_info "$SERVICE_NAME: archiving $GTNH_WORLD"
  if ! docker run --rm --network none \
        --volumes-from "$CONTAINER":ro \
        -v "$DEST:/out" \
        alpine:3 \
        tar --create --gzip \
            --file=/out/"$stamp".tar.gz \
            -C / data/"$GTNH_WORLD" data/serverutilities data/visualprospecting \
            data/config data/server.properties data/whitelist.json data/ops.json; then
    log_err "$SERVICE_NAME: tar via sidecar failed"
    return 1
  fi

  log_info "$SERVICE_NAME: dump ok ($(du -h "$archive" | cut -f1))"
)

do_restore_drill() (
  ensure_dir "$DEST"
  local latest
  latest="$(find "$DEST" -mindepth 1 -maxdepth 1 -type f \
    -name '20??-??-??T??????Z.tar.gz' | sort -r | head -n 1)"
  if [ -z "$latest" ]; then
    log_err "$SERVICE_NAME: no dump to drill"
    return 1
  fi

  local staging; staging="$(mktemp -d -t gtnh-drill.XXXXXX)"
  trap 'rm -rf -- "$staging"' EXIT
  log_info "$SERVICE_NAME: drilling dump $(basename "$latest") into $staging"
  if ! tar -C "$staging" -xzf "$latest"; then
    log_err "$SERVICE_NAME: drill untar failed"
    return 1
  fi
  if [ ! -f "$staging/data/$GTNH_WORLD/level.dat" ] || \
     [ ! -d "$staging/data/$GTNH_WORLD/region" ] || \
     [ ! -f "$staging/data/config/GregTech/Pollution.cfg" ] || \
     [ ! -d "$staging/data/serverutilities" ] || \
     [ ! -d "$staging/data/visualprospecting" ]; then
    log_err "$SERVICE_NAME: drill tarball missing world or supporting state"
    return 1
  fi
  local region_count
  region_count="$(find "$staging/data/$GTNH_WORLD/region" -name '*.mca' | wc -l)"
  if [ "$region_count" -lt 1 ]; then
    log_err "$SERVICE_NAME: drill looks empty (no .mca files)"
    return 1
  fi
  log_info "$SERVICE_NAME: drill ok — $region_count region files"
  find "$DEST" -maxdepth 1 -type f -name '20??-??-??T??????Z.tar.gz' \
    ! -path "$latest" -mtime +"$RETENTION_DAYS" -delete
)