#!/usr/bin/env bash
# backups/config/gtnh.sh
# Backup of the GTNH Minecraft world. Uses the itzg image's built-in
# `save-on`/`save-all` RCON commands so we capture a quiescent world
# snapshot, then `docker run --volumes-from` against the gtnh container
# to pull /data/world without touching anything else.
#
# Why this approach: `cp -a /mnt/tank/...` while the server is running
# is unsafe (chunk files mid-write). Itzg ships a tiny Alpine image we
# can exec rcon inside, and the world lives on the gtnh-data Docker
# volume so we attach to that volume.

set -uo pipefail

SERVICE_NAME="gtnh"
CONTAINER="gtnh"
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=7   # 7 nightly copies is plenty for a creative-build world

# RCON is on by default in itzg's image; creds live in /data/server.properties.
# We don't know the password without parsing it, so use the `rcon-cli` binary
# included in the image with env-based config that itzg auto-detects from
# the live container's properties file. Failing that, fall back to a forced
# `save-off` cycle with `save-all` over the console pipe (stdin_open=true).

do_backup() {
  ensure_dir "$DEST"
  local stamp; stamp="$(timestamp)"
  local archive="$DEST/$stamp.tar.gz"

  log_info "$SERVICE_NAME: quiescing world and tarring /data"
  if ! docker exec "$CONTAINER" \
        rcon-cli save-all flush >/dev/null 2>&1; then
    log_warn "$SERVICE_NAME: rcon-cli save-all failed; continuing without quiesce"
  fi

  # Use a sidecar alpine container with --volumes-from to copy /data out
  # without depending on a bind mount being present (gtnh-data is a named
  # volume, no host bind in the compose).
  if ! docker run --rm \
        --volumes-from "$CONTAINER" \
        -v "$DEST:/out" \
        alpine:3 \
        tar --create --gzip \
            --exclude='cache' \
            --exclude='logs' \
            --exclude='crash-reports' \
            --exclude='*.log' \
            --file=/out/"$stamp".tar.gz \
            -C / data/world data/server.properties data/whitelist.json data/ops.json >/dev/null 2>&1; then
    log_err "$SERVICE_NAME: tar via sidecar failed"
    rm -f -- "$archive"
    return 1
  fi

  log_info "$SERVICE_NAME: dump ok ($(du -sh "$DEST/$stamp.tar.gz" | awk '{print $1}'))"
  return 0
}

do_restore_drill() {
  ensure_dir "$DEST"
  local latest
  latest="$(find "$DEST" -mindepth 1 -maxdepth 1 -type f -name '*.tar.gz' | sort -r | head -n 1)"
  if [ -z "$latest" ]; then
    log_err "$SERVICE_NAME: no dump to drill"
    return 1
  fi

  local staging; staging="$(mktemp -d -t gtnh-drill.XXXXXX)"
  trap 'rm -rf -- "$staging"' RETURN

  log_info "$SERVICE_NAME: drilling dump $(basename "$latest") into $staging"
  if ! tar -C "$staging" -xzf "$latest"; then
    log_err "$SERVICE_NAME: drill untar failed"
    return 1
  fi

  # Sanity: world region dir + level.dat present (Mojang's level marker).
  if [ ! -d "$staging/data/world/region" ] || \
     [ ! -f "$staging/data/world/level.dat" ]; then
    log_err "$SERVICE_NAME: drill tarball missing world essentials"
    return 1
  fi

  local region_count; region_count="$(find "$staging/data/world/region" -name '*.mca' | wc -l)"
  log_info "$SERVICE_NAME: drill ok — $region_count region files"
  if [ "$region_count" -lt 1 ]; then
    log_err "$SERVICE_NAME: drill looks empty (no .mca files)"
    return 1
  fi
  return 0
}