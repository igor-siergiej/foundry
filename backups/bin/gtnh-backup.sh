#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib/common.sh"
source "$HERE/config/gtnh.sh"

backup_and_drill() {
  do_backup && do_restore_drill
}

with_lock "$SERVICE_NAME" backup_and_drill
