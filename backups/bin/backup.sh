#!/usr/bin/env bash
# backups/bin/backup.sh
# Iterate every config/<service>.sh, run do_backup under a per-service lock,
# prune old dumps, post a Discord summary on any failure.
#
# Cron / systemd unit lives at backups/systemd/foundry-backup.{service,timer}.

set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$HERE/lib/common.sh"

declare -i failed=0
declare -a failed_services=()

for cfg in "$HERE"/config/*.sh; do
  [ -f "$cfg" ] || continue
  svc="$(basename "$cfg" .sh)"
  # shellcheck source=/dev/null
  source "$cfg"

  # Source files declare do_backup + do_restore_drill. Reset per-iteration
  # so cross-service env leakage can't poison the next run.
  if ! with_lock "$svc" do_backup; then
    failed_services+=("$svc")
    ((failed++))
  fi
  unset -f do_backup do_restore_drill
  unset SERVICE_NAME CONTAINER MONGO_USER MONGO_PASS DB_USER DATA_DIR DEST RETENTION_DAYS
done

if [ "$failed" -gt 0 ]; then
  msg="**Backup failures** ($(date -u +%Y-%m-%dT%H:%M:%SZ))\n"
  for s in "${failed_services[@]}"; do
    msg+="- \`$s\`\n"
  done
  discord_post "$msg"
  exit 1
fi

log_info "all backups OK"
exit 0