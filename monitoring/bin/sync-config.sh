#!/bin/sh
# Sync the monitoring service configs from the just-cloned repo tree to a
# stable host path. Run as the Dokploy compose's "command" (pre-deploy hook).
#
# Why: every compose-deploy of `monitoring` re-clones the repo to
# /etc/dokploy/compose/<composeId>/code. Containers whose spec did not change
# are not recreated by `docker compose up -d`, so bind mounts to the old
# (now-deleted) tree inode keep the previous in-memory view of the directory
# and any new or edited file silently never reaches the running container
# until a manual `docker restart <name>`. The fix is to mount from a stable
# host path that is not re-cloned, and to refresh it on every deploy from
# the freshly-cloned source.
#
# This script must be run from the cloned repo root, with the working
# directory set by Dokploy.

set -eu

SRC="monitoring/config"
DST="/etc/foundry/monitoring"

if [ ! -d "$SRC" ]; then
    echo "sync-config: $SRC not found in $(pwd); aborting" >&2
    exit 1
fi

mkdir -p "$DST"
# -a preserves mode/ownership/timestamps so file-mode bits in
# /etc/grafana/provisioning etc. don't get reset to 0644 on every deploy
# (which would otherwise break container-side reads when the container runs
# as a non-root user). --delete removes files removed from the repo.
cp -a --delete "$SRC/." "$DST/"
echo "sync-config: $SRC -> $DST"
