#!/usr/bin/env bash
# foundry/smoke/bin/run-smoke.sh
#
# Run the @smoke Playwright specs for each app against its prod URL.
# Posts one Discord message per failing app via the configured webhook URL.
#
# Required environment:
#   DISCORD_WEBHOOK_URL   — incoming-webhook URL for the #homelab channel.
#                           Provided by /etc/foundry/smoke.env (mode 600),
#                           which is rendered from the Vaultwarden item
#                           `foundry.smoke.env` via the bw-render-template
#                           pattern in dotfiles/docs/secrets.md.
#   KANBAN_CLI_REPO_ROOTS — defaults to /home/home/imapps.
#
# Exit code: 0 if every app's @smoke passed, 1 otherwise (after posting).
#
# Cron / systemd unit lives at smoke/systemd/foundry-smoke.{service,timer}.

set -uo pipefail

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
  echo "[smoke] DISCORD_WEBHOOK_URL not set — refusing to run silently" >&2
  exit 2
fi

export KANBAN_CLI_REPO_ROOTS="${KANBAN_CLI_REPO_ROOTS:-/home/home/imapps}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Each entry is a checkout directory next to foundry (../<name>) whose
# .kanban-cli.json supplies the production baseUrl (tandra: https://app.tandra.uk).
APPS=(tandra jewellery-catalogue kivo mixtape)

WORKDIR="$(mktemp -d -t foundry-smoke.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

run_one() {
  local name="$1"
  local cfg="$REPO_ROOT/../$name/.kanban-cli.json"
  if [ ! -f "$cfg" ]; then
    echo "[smoke] $name: no .kanban-cli.json, skipping"
    printf 'skipped (no .kanban-cli.json)\n'
    return 0
  fi

  local base_url
  base_url="$(jq -r '.environments.production.baseUrl // empty' "$cfg")"
  if [ -z "$base_url" ]; then
    echo "[smoke] $name: no environments.production.baseUrl, skipping"
    printf 'skipped (no production.baseUrl)\n'
    return 0
  fi

  local out="$WORKDIR/$name.json"
  local started
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "[smoke] $name: running @smoke against $base_url"
  if kanban-cli e2e live "$REPO_ROOT/../$name" \
        --url "$base_url" >"$out" 2>&1; then
    local passed
    passed="$(jq -r '.passed // false' "$out" 2>/dev/null || echo false)"
    if [ "$passed" = "true" ]; then
      echo "[smoke] $name: OK"
      return 0
    fi
  fi

  # Failure path. Build a triage block: failing tests + recent container log tail.
  local failed_tests
  failed_tests="$(jq -r '.failedTests // [] | map("  - \(.title // .name // "?")\n    \(.error // "")") | join("\n")' \
                   "$out" 2>/dev/null || echo "(could not parse failure detail)")"
  local log_tail
  log_tail="$(docker logs --tail 40 "$(jq -r '.name // empty' "$out" 2>/dev/null)" 2>/dev/null \
              | tail -25 || true)"
  local last_deploy
  last_deploy="$(mcp-cli --config /home/home/.mcp_servers.json \
                   call-tool dokploy-mcp:deployment.allByCompose \
                   --args "$(jq -nc --arg n "$name" '{composeName: $n, limit: 1}')" 2>/dev/null \
                 | jq -r '.[] | "  - \(.deploymentId) at \(.createdAt)"' 2>/dev/null \
                 | head -3 || true)"

  jq -nc \
    --arg app "$name" \
    --arg url "$base_url" \
    --arg started "$started" \
    --arg failed "$failed_tests" \
    --arg logs "$log_tail" \
    --arg deploy "$last_deploy" \
    '{
       app: $app,
       url: $url,
       startedAt: $started,
       failedTests: $failed,
       containerLogTail: $logs,
       lastDeploys: $deploy
     }' \
    > "$WORKDIR/$name.triage.json"

  echo "[smoke] $name: FAIL"
  return 1
}

declare -i total_fails=0
declare -a failed_apps=()

for app in "${APPS[@]}"; do
  if ! run_one "$app" "$REPO_ROOT"; then
    failed_apps+=("$app")
    ((total_fails++))
  fi
done

if [ "$total_fails" -eq 0 ]; then
  echo "[smoke] all OK"
  exit 0
fi

# Build one Discord message summarising every failing app.
content="**Nightly prod smoke: ${total_fails} app(s) failed** ($(date -u +%Y-%m-%dT%H:%M:%SZ))\n"
for app in "${failed_apps[@]}"; do
  triage="$(cat "$WORKDIR/$app.triage.json")"
  failed="$(jq -r '.failedTests // "(no detail)"' <<<"$triage")"
  last_deploy="$(jq -r '.lastDeploys // "(no deploys found)"' <<<"$triage")"
  content+="\n__${app}__ — $(jq -r '.url' <<<"$triage")\n"
  content+="Failed tests:\n\`\`\`\n${failed}\n\`\`\`\n"
  content+="Recent deploys:\n${last_deploy}\n"
done

# Discord hard-caps content at 2000 chars; truncate if needed.
if [ "${#content}" -gt 1900 ]; then
  content="${content:0:1900}\n…(truncated; full triage in \$WORKDIR/$app.triage.json)"
fi

payload="$(jq -nc --arg c "$content" '{content: $c}')"

if ! curl -fsS -X POST "$DISCORD_WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "$payload"; then
  echo "[smoke] Discord POST failed" >&2
fi

# Tee the full triage for follow-up.
echo "---- triage ----"
for app in "${failed_apps[@]}"; do
  echo "=== $app ==="
  cat "$WORKDIR/$app.triage.json"
  echo
done

exit 1