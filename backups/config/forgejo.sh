#!/usr/bin/env bash
# backups/config/forgejo.sh
# Backup of Forgejo (git.imapps.uk): the source of truth for jott's git history.
#
# Strategy: Python's SQLite online backup API snapshots gitea/gitea.db,
# including committed WAL data. Archive it with bare repositories, app.ini,
# JWT/Actions signing keys and git/.ssh. Generated push-mirror SSH keys are
# encrypted in the DB; app.ini's SECRET_KEY is required to decrypt them.
# Attachments/LFS/packages are not used yet and are not included.
#
# Repositories are copied live, not atomically with the database. The restore
# drill checks every copied repository with git fsck; stop writes for a fully
# application-consistent recovery point before upgrades.

set -uo pipefail

SERVICE_NAME="forgejo"
DATA_DIR="/mnt/tank/shared/forgejo"
DEST="$BACKUPS_ROOT/$SERVICE_NAME"
RETENTION_DAYS=14

do_backup() (
  umask 077
  ensure_dir "$DEST" || return 1
  local stamp; stamp="$(timestamp)"
  local staging="$DEST/$stamp"
  local archive="$DEST/$stamp.tar.gz"

  if [ ! -s "$DATA_DIR/gitea/conf/app.ini" ] || [ ! -s "$DATA_DIR/gitea/gitea.db" ] || \
     [ ! -d "$DATA_DIR/git/repositories" ]; then
    log_err "$SERVICE_NAME: required app.ini, database or repository directory missing/empty"
    return 1
  fi
  mkdir -m 700 -- "$staging" || return 1
  trap 'rm -rf -- "$staging"; rm -f -- "$archive.tmp"' EXIT

  if ! python3 - "$DATA_DIR/gitea/gitea.db" "$staging/gitea.db" <<'PY'
from pathlib import Path
import sqlite3
import sys

try:
    # mode=ro prevents a missing source from becoming a new empty database.
    source = sqlite3.connect(Path(sys.argv[1]).resolve().as_uri() + "?mode=ro", uri=True)
    target = sqlite3.connect(sys.argv[2])
    try:
        source.backup(target)
        if target.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ValueError("snapshot integrity check failed")
        if target.execute('SELECT count(*) FROM "user"').fetchone()[0] < 1:
            raise ValueError("snapshot has no users")
    finally:
        target.close()
        source.close()
except (sqlite3.Error, ValueError):
    # Do not print SQL, connection details or secret-bearing database values.
    sys.exit("forgejo: SQLite snapshot failed integrity/schema/user checks")
PY
  then
    log_err "$SERVICE_NAME: online SQLite backup failed"
    return 1
  fi

  mkdir -p -- "$staging/gitea/conf" "$staging/git" || return 1
  cp -- "$DATA_DIR/gitea/conf/app.ini" "$staging/gitea/conf/app.ini" || return 1
  local path
  for path in gitea/jwt gitea/actions_id_token git/.ssh; do
    if [ -d "$DATA_DIR/$path" ]; then
      rsync -a "$DATA_DIR/$path/" "$staging/$path/" || return 1
    fi
  done
  rsync -a "$DATA_DIR/git/repositories/" "$staging/git/repositories/" || return 1
  chmod -R go-rwx -- "$staging" || return 1

  # Publish only a complete archive; a failed tar is never a valid drill input.
  tar -C "$DEST" -czf "$archive.tmp" "$stamp" || return 1
  chmod 600 "$archive.tmp" || return 1
  mv -- "$archive.tmp" "$archive" || return 1
  log_info "$SERVICE_NAME: backup ok ($archive)"
)

do_restore_drill() (
  umask 077
  ensure_dir "$DEST" || return 1
  local latest
  latest="$(find "$DEST" -mindepth 1 -maxdepth 1 -type f -name '*.tar.gz' | sort -r | head -n 1)"
  if [ -z "$latest" ]; then
    log_err "$SERVICE_NAME: no dump to drill"
    return 1
  fi

  local stamp; stamp="$(basename "$latest" .tar.gz)"
  local staging
  staging="$(mktemp -d "$DEST/.drill-$stamp.XXXXXX")" || return 1
  trap 'rm -rf -- "$staging"' EXIT

  log_info "$SERVICE_NAME: drilling dump $stamp"
  tar -C "$staging" -xzf "$latest" || return 1
  local restored="$staging/$stamp"
  if [ ! -s "$restored/gitea.db" ] || [ ! -s "$restored/gitea/conf/app.ini" ] || \
     [ ! -d "$restored/git/repositories" ]; then
    log_err "$SERVICE_NAME: drill archive missing database, app.ini or repositories"
    return 1
  fi

  local counts users expected_repos
  if ! counts="$(python3 - "$restored/gitea.db" <<'PY'
from pathlib import Path
import sqlite3
import sys

try:
    db = sqlite3.connect(Path(sys.argv[1]).resolve().as_uri() + "?mode=ro", uri=True)
    try:
        if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ValueError("integrity check failed")
        users = db.execute('SELECT count(*) FROM "user"').fetchone()[0]
        if users < 1:
            raise ValueError("no users")
        repositories = db.execute("SELECT count(*) FROM repository").fetchone()[0]
        if repositories < 1:
            raise ValueError("no repositories")
        print(users, repositories)
    finally:
        db.close()
except (sqlite3.Error, ValueError):
    sys.exit("forgejo: restored SQLite database failed integrity/schema/user/repository checks")
PY
  )"; then
    log_err "$SERVICE_NAME: restored database validation failed"
    return 1
  fi

  read -r users expected_repos <<< "$counts"
  local repo_list="$staging/repositories.list"
  if ! find "$restored/git/repositories" -mindepth 2 -maxdepth 2 -type d -name '*.git' -print0 > "$repo_list"; then
    log_err "$SERVICE_NAME: repository enumeration failed"
    return 1
  fi

  local repos=0 primary_repos=0 bad=0 repo
  while IFS= read -r -d '' repo; do
    repos=$((repos + 1))
    case "$repo" in
      *.wiki.git) ;;
      *) primary_repos=$((primary_repos + 1)) ;;
    esac
    if ! git -c safe.directory="$repo" --git-dir="$repo" fsck --no-progress >/dev/null 2>&1; then
      log_err "$SERVICE_NAME: git fsck failed for ${repo#"$restored/git/repositories/"}"
      bad=$((bad + 1))
    fi
  done < "$repo_list"

  if [ "$primary_repos" -lt "$expected_repos" ]; then
    log_err "$SERVICE_NAME: repository count mismatch (database=$expected_repos restored_primary=$primary_repos)"
    return 1
  fi
  if [ "$bad" -gt 0 ]; then
    log_err "$SERVICE_NAME: drill sanity failed (integrity=ok users=$users repos=$repos fsck_failed=$bad)"
    return 1
  fi
  log_info "$SERVICE_NAME: drill ok: integrity=ok users=$users repos=$repos primary_repos=$primary_repos database_repos=$expected_repos fsck=ok"
)
