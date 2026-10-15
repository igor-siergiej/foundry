#!/usr/bin/env bash
# backups/config/homeassistant.sh
# Backup of Home Assistant configuration. HA is on a bridge network with no
# host-DB process; the bind-mounted /mnt/tank/shared/homeassistant/config
# IS the state (yaml, .storage/, custom_components/). ZFS mirror covers
# drive loss, but backups cover accidental `rm` + the 2026-08-20-style
# full reset.
#
# Strategy: tar of the bind-mounted config dir, excluding the recorder DB
# (large, low-value; HA rebuilds it from event log if missing) and the
# deps/ dir (transient Python venv, easy to recreate).

set -uo pipefail

SERVICE_NAME="homeassistant"
DATA_DIR="/mnt/tank/shared/homeassistant/config"
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=14

do_backup() {
  ensure_dir "$DEST"
  local stamp; stamp="$(timestamp)"
  local archive="$DEST/$stamp.tar.gz"

  if [ ! -d "$DATA_DIR" ]; then
    log_err "$SERVICE_NAME: $DATA_DIR not mounted"
    return 1
  fi

  # tar --exclude caches the relative root, so we cd first.
  log_info "$SERVICE_NAME: tar-ing $DATA_DIR into $archive"
  if ! tar --create --gzip \
        --file="$archive" \
        --exclude='deps' \
        --exclude='home-assistant_v2.db*' \
        -C "$DATA_DIR" \
        .; then
    log_err "$SERVICE_NAME: tar failed"
    rm -f -- "$archive"
    return 1
  fi

  log_info "$SERVICE_NAME: dump ok ($(du -sh "$archive" | awk '{print $1}'))"
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

  local staging; staging="$(mktemp -d -t ha-drill.XXXXXX)"
  trap 'rm -rf -- "$staging"' RETURN

  log_info "$SERVICE_NAME: drilling dump $(basename "$latest") into $staging"
  if ! tar -C "$staging" -xzf "$latest"; then
    log_err "$SERVICE_NAME: drill untar failed"
    return 1
  fi

  # Sanity: configuration.yaml + .storage/core.config_entries present.
  if [ ! -f "$staging/configuration.yaml" ] || \
     [ ! -d "$staging/.storage" ]; then
    log_err "$SERVICE_NAME: drill tarball missing essentials"
    return 1
  fi

  # Count of integrations registered — proxy for "this isn't a fresh install".
  local entries
  entries="$(jq -r '.data.entries | length // 0' \
              "$staging/.storage/core.config_entries" 2>/dev/null \
              || echo 0)"

  if [ -z "$entries" ] || [ "$entries" -lt 1 ]; then
    log_err "$SERVICE_NAME: drill config_entries looks empty (entries=$entries)"
    return 1
  fi

  log_info "$SERVICE_NAME: drill ok — entries=$entries"
  return 0
}