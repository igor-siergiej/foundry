#!/usr/bin/env bash
# backups/bin/stale-check.sh
# Walk every config/<service>.sh, look at the newest dump's mtime, and
# alert if it's older than 2× its declared RETENTION_DAYS-but-in-practice
# "schedule". Each service has a SCHEDULE_DAYS env var override; defaults
# to RETENTION_DAYS / 2 (i.e. weekly schedules expect backups within 2 days).
#
# Run hourly via systemd — keeps alerts cheap.

set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"

declare -a stale=()

now_epoch="$(date +%s)"

for cfg in "$HERE"/config/*.sh; do
  [ -f "$cfg" ] || continue
  svc="$(basename "$cfg" .sh)"
  # shellcheck source=/dev/null
  source "$cfg"

  # SCHEDULE_DAYS overrides RETENTION_DAYS-derived expectation.
  local_schedule_days="${SCHEDULE_DAYS:-$(( RETENTION_DAYS / 2 ))}"

  local dest="$BACKUPS_ROOT/$svc"
  if [ ! -d "$dest" ]; then
    stale+=("$svc (no $dest/)")
    continue
  fi

  local latest
  latest="$(find "$dest" -mindepth 1 \( -type f -o -type d \) \
              | sort -r | head -n 1)"
  if [ -z "$latest" ]; then
    stale+=("$svc (empty $dest/)")
    continue
  fi

  local mtime_epoch; mtime_epoch="$(stat -c %Y "$latest")"
  local age_days=$(( (now_epoch - mtime_epoch) / 86400 ))
  if [ "$age_days" -gt "$local_schedule_days" ]; then
    stale+=("$svc (last: $age_days d ago, threshold: $local_schedule_days d)")
  fi

  unset -f do_backup do_restore_drill
  unset SERVICE_NAME CONTAINER MONGO_USER MONGO_PASS DB_USER DATA_DIR DEST RETENTION_DAYS SCHEDULE_DAYS local_schedule_days latest mtime_epoch age_days
done

if [ "${#stale[@]}" -gt 0 ]; then
  msg="**Stale backups** ($(date -u +%Y-%m-%dT%H:%M:%SZ))\n"
  for s in "${stale[@]}"; do
    msg+="- \`$s\`\n"
  done
  discord_post "$msg"
  exit 1
fi

log_info "all backups fresh"
exit 0