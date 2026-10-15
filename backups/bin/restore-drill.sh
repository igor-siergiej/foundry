#!/usr/bin/env bash
# backups/bin/restore-drill.sh
# Weekly drill: for every service with a config, restore its newest dump
# into a throwaway container (or tempdir for SQLite), run a sanity check,
# tear it down. Posts a Discord summary on any failure.
#
# Runs Sundays at 02:30 via systemd. Each config's do_restore_drill must
# use a throwaway container with `--network none` and a non-prod port, as
# documented in the homelab.md §7 "no prod network, no prod ports".

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

  if ! with_lock "$svc" do_restore_drill; then
    failed_services+=("$svc")
    ((failed++))
  fi
  unset -f do_backup do_restore_drill
  unset SERVICE_NAME CONTAINER MONGO_USER MONGO_PASS DB_USER DATA_DIR DEST RETENTION_DAYS
done

if [ "$failed" -gt 0 ]; then
  msg="**Restore-drill failures** ($(date -u +%Y-%m-%dT%H:%M:%SZ)) — last backup could not be restored\n"
  for s in "${failed_services[@]}"; do
    msg+="- \`$s\`\n"
  done
  discord_post "$msg"
  exit 1
fi

log_info "restore-drill OK for every service"
exit 0