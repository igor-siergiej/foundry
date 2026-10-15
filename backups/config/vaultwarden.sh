#!/usr/bin/env bash
# backups/config/vaultwarden.sh
# Backup of Vaultwarden — the root of all secrets. Per the foundry board this
# has to be backed up because everything else depends on it.
#
# Strategy: SQLite `.backup` (WAL-safe online backup) + RSA key + icon cache,
# tar'd together. SQLite's `.backup` is the only safe online backup for SQLite
# while writers are attached — `cp` against a live SQLite can give a
# half-written DB.
#
# Vaultwarden stores its DB at /data/db.sqlite3 inside the container, but
# the host bind (see /mnt/tank/shared/vaultwarden/) is the source of truth.

set -uo pipefail

SERVICE_NAME="vaultwarden"
DATA_DIR="/mnt/tank/shared/vaultwarden"
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=14   # vault stores everything; keep more history

do_backup() {
  ensure_dir "$DEST"
  local stamp; stamp="$(timestamp)"
  local staging="$DEST/$stamp"
  ensure_dir "$staging"

  if [ ! -d "$DATA_DIR" ]; then
    log_err "$SERVICE_NAME: $DATA_DIR not mounted"
    return 1
  fi

  # WAL-safe online backup using the sqlite3 CLI.
  if ! sqlite3 "$DATA_DIR/db.sqlite3" ".backup '$staging/db.sqlite3'"; then
    log_err "$SERVICE_NAME: sqlite .backup failed"
    rm -rf -- "$staging"
    return 1
  fi

  # RSA private key — needed to decrypt the vault.
  if [ -f "$DATA_DIR/rsa_key.pem" ]; then
    cp -- "$DATA_DIR/rsa_key.pem" "$staging/rsa_key.pem"
    chmod 600 "$staging/rsa_key.pem"
  else
    log_warn "$SERVICE_NAME: no rsa_key.pem at $DATA_DIR (vault may not have a private key)"
  fi

  # Icon cache — small, but losing it just rebuilds from items on next login.
  if [ -d "$DATA_DIR/icon_cache" ]; then
    rsync -a --delete "$DATA_DIR/icon_cache/" "$staging/icon_cache/"
  fi

  # Pack everything for atomicity.
  local archive="$DEST/$stamp.tar.gz"
  tar -C "$DEST" -czf "$archive" "$stamp"
  rm -rf -- "$staging"

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

  local stamp; stamp="$(basename "$latest" .tar.gz)"
  local staging="$DEST/.drill-$stamp"
  rm -rf -- "$staging"
  ensure_dir "$staging"

  log_info "$SERVICE_NAME: drilling dump $stamp into $staging"
  tar -C "$staging" -xzf "$latest"

  local db="$staging/$stamp/db.sqlite3"
  if [ ! -f "$db" ]; then
    log_err "$SERVICE_NAME: drill tarball missing db.sqlite3"
    rm -rf -- "$staging"
    return 1
  fi

  # Sanity: sqlite integrity check + row count of users table.
  local integrity rows
  integrity="$(sqlite3 "$db" "PRAGMA integrity_check;" 2>&1 | head -1)"
  rows="$(sqlite3 "$db" "select count(*) from users;" 2>/dev/null | tr -d ' \n' || echo 0)"

  rm -rf -- "$staging"

  if [ "$integrity" != "ok" ] || [ -z "$rows" ] || [ "$rows" -lt 1 ]; then
    log_err "$SERVICE_NAME: drill sanity failed (integrity=$integrity users=$rows)"
    return 1
  fi

  log_info "$SERVICE_NAME: drill ok — integrity=ok users=$rows"
  return 0
}