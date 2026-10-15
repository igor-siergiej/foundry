# Nightly prod smoke routine

Runs each app's `@smoke` Playwright specs against production, once a night,
and posts a Discord alert on failure.

Gatus only checks that endpoints respond — not that core flows work
(images 404/401, a fal key failing, a misconfigured redirect, etc).
This is the second layer: real end-to-end flows.

## What runs

- `smoke/bin/run-smoke.sh` — iterates over `shoppingo`, `jewellery-catalogue`,
  `kivo`, `mixtape`. For each, calls `kanban-cli e2e live <repo> --url
  <production baseUrl>` (which runs only `@smoke`-tagged specs by default,
  scoped to that repo's `e2e.smokeGrep` from `.kanban-cli.json`).
- Apps without a `.kanban-cli.json` or `environments.production.baseUrl` are
  skipped with a log line — they're added when the kanban-worker bootstraps
  them.

## Failure path

When one or more apps fail:

1. Each failing app's triage (failed tests, container log tail, last
   Dokploy deploy) is captured under `$WORKDIR/<app>.triage.json`.
2. One Discord message is posted per run (not per app) with a summary
   block per failing app.
3. The systemd unit exits non-zero so `journalctl -u foundry-smoke` shows it.

## Deploy

The timer lives on the `foundry` host itself.

```sh
# Render the env file once (vault item `foundry.smoke.env`,
# KEY=VALUE format like the rest of the dotfiles secrets pattern).
sudo install -m 0600 /dev/null /etc/foundry/smoke.env
# edit DISCORD_WEBHOOK_URL into it
sudo systemctl link smoke/systemd/foundry-smoke.service \
                    smoke/systemd/foundry-smoke.timer \
                    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now foundry-smoke.timer
```

`/etc/foundry/smoke.env` is **mode 600**, owned by root, and contains only
the Discord webhook URL. Render it once by hand; the foundry service
process reads it as the `EnvironmentFile=`. The webhook URL is *not* in
the foundry repo or in Vaultwarden unless you put it there — the dotfiles
secrets pattern (`docs/secrets.md`) supports either.

## Local run (manual triage)

```sh
sudo systemd-run --uid=home --setenv=DISCORD_WEBHOOK_URL=... \
                 /home/home/imapps/foundry/smoke/bin/run-smoke.sh
```

## Test-account credentials

Each app needs a dedicated test account whose credentials live in
Vaultwarden. Those items are *not* created by this routine — they're
created by hand following the dotfiles `secrets.md` pattern, and each
app's Playwright config reads them at runtime via `bw-run`. The four
items to create (one per app) are:

- `smoke.shoppingo.account`
- `smoke.jewellery-catalogue.account`
- `smoke.kivo.account`
- `smoke.mixtape.account`

Until those exist, the corresponding app's `@smoke` tests either skip the
login flow or fail when they hit it.

## Verifying it actually alerts

To verify the failure → Discord path end-to-end without breaking prod,
add a deliberately failing test to one app's suite tagged `@smoke`,
push, wait for the next 03:15 timer, then remove the test. A simpler
manual check:

```sh
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/... \
  /home/home/imapps/foundry/smoke/bin/run-smoke.sh --dry-run
```

(`--dry-run` isn't implemented yet — track as a follow-up if needed.)

## What this is not

- Not a replacement for Gatus. Gatus is per-minute; this is nightly and
  slower.
- Not a load test. Playwright specs are functional checks, not perf.
- Not an LLM triage. The first cut posts raw failure data. Wiring an
  agent in for "probable cause and suggested fix" is tracked as a
  follow-up — Discord messages larger than 2000 chars already truncate.