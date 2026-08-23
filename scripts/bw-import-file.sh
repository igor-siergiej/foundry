#!/usr/bin/env bash
# bw-import-file.sh <item-name> <file-path>
# Stores <file-path>'s full contents as a Secure Note named <item-name>.
# Requires BW_SESSION already exported (run `export BW_SESSION=$(bw unlock --raw)` first).
set -euo pipefail

if [ -z "${BW_SESSION:-}" ]; then
  echo "BW_SESSION not set — run: export BW_SESSION=\$(bw unlock --raw)" >&2
  exit 1
fi

name="$1"
file="$2"

if [ ! -f "$file" ]; then
  echo "No such file: $file" >&2
  exit 1
fi

bw get template item | \
  jq --arg name "$name" --arg notes "$(cat "$file")" \
     '.type=2 | .name=$name | .secureNote={type:0} | .notes=$notes' | \
  bw encode | bw create item >/dev/null

echo "Created vault item: $name"
