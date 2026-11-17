#!/usr/bin/env bash
# Forgejo-only user timer entrypoint; install with backups/{lib,config} beside forgejo/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BACKUPS_ROOT="${BACKUPS_ROOT:-/mnt/tank/shared/forgejo-backups}"
LOCK_DIR="${LOCK_DIR:-${XDG_RUNTIME_DIR:?user runtime directory required}/forgejo-backup}"
export BACKUPS_ROOT LOCK_DIR
source "$HERE/../backups/lib/common.sh"
source "$HERE/../backups/config/forgejo.sh"

backup_and_drill() (
  umask 077
  mkdir -p -- "$BACKUPS_ROOT"
  chmod 700 -- "$BACKUPS_ROOT"
  local pending
  pending="$(mktemp -d "$BACKUPS_ROOT/.pending.XXXXXX")"
  trap 'rm -rf -- "$pending"' EXIT
  local retained_root="$BACKUPS_ROOT"
  BACKUPS_ROOT="$pending"
  DEST="$BACKUPS_ROOT/forgejo"
  do_backup
  do_restore_drill
  BACKUPS_ROOT="$retained_root"

  # Group each proven archive in a timestamp directory for retain_dumps.
  local archive stamp
  local -a archives=("$DEST"/*.tar.gz)
  [ "${#archives[@]}" -eq 1 ] && [ -f "${archives[0]}" ]
  archive="${archives[0]}"
  stamp="$(basename "$archive" .tar.gz)"
  ensure_dir "$BACKUPS_ROOT/forgejo"
  mv -T -- "$DEST" "$BACKUPS_ROOT/forgejo/$stamp"
  retain_dumps forgejo "$RETENTION_DAYS"
  log_info "forgejo: retained proven archive $BACKUPS_ROOT/forgejo/$stamp/$stamp.tar.gz"
)

with_lock forgejo backup_and_drill
