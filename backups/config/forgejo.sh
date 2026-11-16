#!/usr/bin/env bash
# backups/config/forgejo.sh
# Backup of Forgejo (git.imapps.uk): the source of truth for jott's git history.
#
# Strategy: SQLite `.backup` (WAL-safe online backup) of /data/gitea/gitea.db
# (the default [database] PATH in the image's app.ini template), plus the bare
# repositories (git/repositories), app.ini and the JWT/secret material under
# gitea/ needed to restore, tar'd together. No attachments/LFS/packages are
# used yet, so they are not included; add them when that changes.
#
# Repositories are copied while Forgejo runs. Git objects are immutable and
# refs are updated atomically, so the copy is consistent enough for `git fsck`;
# the nightly cadence makes a torn ref update self-healing on the next run.

set -uo pipefail

SERVICE_NAME="forgejo"
DATA_DIR="/mnt/tank/shared/forgejo"
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=14

do_backup() {
  ensure_dir "$DEST"
  local stamp; stamp="$(timestamp)"
  local staging="$DEST/$stamp"
  ensure_dir "$staging"

  if [ ! -d "$DATA_DIR/gitea" ]; then
    log_err "$SERVICE_NAME: $DATA_DIR/gitea not mounted"
    rm -rf -- "$staging"
    return 1
  fi

  # WAL-safe online backup using the sqlite3 CLI.
  if ! sqlite3 "$DATA_DIR/gitea/gitea.db" ".backup '$staging/gitea.db'"; then
    log_err "$SERVICE_NAME: sqlite .backup failed"
    rm -rf -- "$staging"
    return 1
  fi

  # app.ini + jwt/ hold the secret keys (SECRET_KEY, JWT, LFS) needed to make
  # a restored DB usable (2FA, tokens, sessions).
  ensure_dir "$staging/gitea"
  if [ -f "$DATA_DIR/gitea/conf/app.ini" ]; then
    ensure_dir "$staging/gitea/conf"
    cp -- "$DATA_DIR/gitea/conf/app.ini" "$staging/gitea/conf/app.ini"
    chmod 600 "$staging/gitea/conf/app.ini"
  else
    log_warn "$SERVICE_NAME: no gitea/conf/app.ini at $DATA_DIR"
  fi
  if [ -d "$DATA_DIR/gitea/jwt" ]; then
    rsync -a "$DATA_DIR/gitea/jwt/" "$staging/gitea/jwt/"
  fi

  if [ -d "$DATA_DIR/git/repositories" ]; then
    ensure_dir "$staging/git"
    rsync -a "$DATA_DIR/git/repositories/" "$staging/git/repositories/"
  else
    log_warn "$SERVICE_NAME: no git/repositories at $DATA_DIR"
  fi

  # Pack everything for atomicity.
  local archive="$DEST/$stamp.tar.gz"
  tar -C "$DEST" -czf "$archive" "$stamp"
  rm -rf -- "$staging"
  chmod 600 "$archive"

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

  local db="$staging/$stamp/gitea.db"
  if [ ! -f "$db" ]; then
    log_err "$SERVICE_NAME: drill tarball missing gitea.db"
    rm -rf -- "$staging"
    return 1
  fi

  local integrity users
  integrity="$(sqlite3 "$db" "PRAGMA integrity_check;" 2>&1 | head -1)"
  users="$(sqlite3 "$db" 'select count(*) from "user";' 2>/dev/null | tr -d ' \n' || echo 0)"

  # git fsck every restored repo (usually a handful); any failure fails the drill.
  local repos=0 bad=0 repo
  while IFS= read -r repo; do
    repos=$((repos + 1))
    if ! git --git-dir="$repo" fsck --no-progress >/dev/null 2>&1; then
      log_err "$SERVICE_NAME: git fsck failed for ${repo#"$staging/$stamp/git/repositories/"}"
      bad=$((bad + 1))
    fi
  done < <(find "$staging/$stamp/git/repositories" -mindepth 2 -maxdepth 2 -type d -name '*.git' 2>/dev/null)

  rm -rf -- "$staging"

  if [ "$integrity" != "ok" ] || [ -z "$users" ] || [ "$users" -lt 1 ] || [ "$bad" -gt 0 ]; then
    log_err "$SERVICE_NAME: drill sanity failed (integrity=$integrity users=$users repos=$repos fsck_failed=$bad)"
    return 1
  fi

  log_info "$SERVICE_NAME: drill ok — integrity=ok users=$users repos=$repos fsck=ok"
  return 0
}
