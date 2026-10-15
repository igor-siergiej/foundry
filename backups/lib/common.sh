#!/usr/bin/env bash
# backups/lib/common.sh
# Shared helpers for the foundry backup suite. Sourced by every config/*.sh,
# bin/backup.sh, bin/restore-drill.sh and bin/stale-check.sh.
#
# Provides:
#   log_info / log_warn / log_err — formatted stderr log lines.
#   lock_for_service — per-service file lock under /var/lock/foundry-backup/.
#   with_lock — wrapper that takes/releases the lock for the calling service.
#   timestamp — UTC YYYYMMDD-HHMMSS, used as the backup directory name.
#   ensure_dir — mkdir -p and chmod 750 (owner=root, group=home).
#   discord_post — POST a one-line message to the webhook in $DISCORD_WEBHOOK_URL.
#
# Honours environment:
#   BACKUPS_ROOT  — root for dump output. Defaults to /mnt/tank/shared/backups.
#   DISCORD_WEBHOOK_URL — required by discord_post; empty disables posting.
#
# Why these helpers exist in one file: every config/<service>.sh and every
# bin/*.sh needs the same logging, locking and Discord plumbing; copying that
# around is what made the old hand-rolled cron backups drift.

set -uo pipefail

BACKUPS_ROOT="${BACKUPS_ROOT:-/mnt/tank/shared/backups}"
LOCK_DIR="${LOCK_DIR:-/var/lock/foundry-backup}"

# ---- logging ----

log_info() { printf '[%s] [INFO] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_warn() { printf '[%s] [WARN] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_err()  { printf '[%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

timestamp() { date -u +%Y-%m-%dT%H%M%SZ; }

ensure_dir() {
  local d="$1"
  mkdir -p -- "$d"
  chmod 750 -- "$d" 2>/dev/null || true
}

# ---- locking ----

lock_for_service() {
  local svc="$1"
  ensure_dir "$LOCK_DIR"
  printf '%s\n' "$$" > "$LOCK_DIR/$svc.lock"
}

unlock_for_service() {
  local svc="$1"
  rm -f -- "$LOCK_DIR/$svc.lock"
}

# with_lock SERVICE BODY...
# Runs BODY under a per-service file lock; exits non-zero if another run
# for the same service is in flight. Designed for cron/timer overlap, not
# high contention (each service has at most one nightly job).
with_lock() {
  local svc="$1"; shift
  local lock="$LOCK_DIR/$svc.lock"

  ensure_dir "$LOCK_DIR"
  if [ -e "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
    log_err "$svc: another run is in flight (pid $(cat "$lock"))"
    return 1
  fi

  lock_for_service "$svc"
  trap 'unlock_for_service "$svc"' RETURN
  "$@"
}

# ---- Discord ----

discord_post() {
  local message="$1"
  if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    log_warn "DISCORD_WEBHOOK_URL not set — would have posted: $message"
    return 0
  fi

  local payload
  payload="$(jq -nc --arg c "$message" '{content: $c}')"
  if ! curl -fsS --max-time 15 -X POST "$DISCORD_WEBHOOK_URL" \
         -H 'Content-Type: application/json' \
         -d "$payload" >/dev/null; then
    log_err "Discord POST failed (see payload above)"
    return 1
  fi
}

# ---- retention ----

# retain_dumps SERVICE MAX
# Keeps the most recent MAX timestamped dump directories under
# $BACKUPS_ROOT/$SERVICE, removes the rest. Directories are sorted
# lexicographically; the timestamp() format is ISO-like so lexical sort
# is chronological.
retain_dumps() {
  local svc="$1" max="$2"
  local dir="$BACKUPS_ROOT/$svc"
  if [ ! -d "$dir" ]; then return 0; fi

  local -a keep
  mapfile -t keep < <(find "$dir" -mindepth 1 -maxdepth 1 -type d \
                         | sort -r \
                         | head -n "$max")

  find "$dir" -mindepth 1 -maxdepth 1 -type d \
    | sort -r \
    | tail -n +"$((max + 1))" \
    | while IFS= read -r old; do
        log_info "$svc: pruning $(basename "$old")"
        rm -rf -- "$old"
      done
}