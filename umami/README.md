# Umami — self-hosted analytics

## Why

Shoppingo's only telemetry today is the JSON `POST /api/logs` route through
Loki (operational logs in [`docs/homelab.md` §10](../docs/homelab.md)).
That doesn't tell us whether people are actually using Discover / the
use-up pantry search or whether the recipe-import path is fine. With
~50 active shoppers across all features, hosted PostHog is overkill (and
officially unsupported on a 4-vCPU / shared-RAM box); the Umami image
fits easily and is what [jott #72 / foundry #101] landed on.

Decided **2026-10-16.** One instance, one "website" per consumer app —
shoppingo first, jewellery-catalogue next, sentinel uses Loki only.

## Topology

| Service | Image | Port | Notes |
|---|---|---|---|
| `umami` | `umami-software/umami@sha256:6cd9d24a…` | 3000 (internal) | Dashboard; routed through Traefik at `analytics.imapps.uk`, Cloudflare Access require-email. |
| `umami-db` | `postgres:16-alpine@sha256:1a66d744…` | 5432 (internal-only on `umami` network) | Bind-mounted `/mnt/tank/shared/umami`; `TZ=UTC`. |

Both containers are joined to the `dokploy-network` so Traefik can
route; the `umami` network stays internal so the analytics DB isn't
reachable from every other app on `dokploy-network`.

## Endpoints

Umami's defaults are renamed to dodge common adblock / privacy lists:

| Env var | Default | This deployment | Why |
|---|---|---|---|
| `TRACKER_SCRIPT_NAME` | `script.js` | `p.js` | Reduces the EasyPrivacy hit rate on the tracker file. |
| `COLLECT_API_ENDPOINT` | `/api/send` | `/p` | Same. |
| `BASE_PATH` | `/` | `/` | — |

The shoppingo web app proxies `/p` to `analytics.imapps.uk/p` via nginx
so the script is same-origin, and the CSP allows it without listing
`analytics.imapps.uk`. A self-host on a single box can use the
analytics env var in [`packages/web/analytics.ts`](../../shoppingo/packages/web/src/analytics.ts)
to skip the tracker entirely (turning it off → no host either).

## Cloudflare Access

- `analytics.imapps.uk` ← **require-email** for the dashboard only
  (`/login`, `/settings`, `/api/...` admin). gatus + admin UI flow
  goes via the same Access app.
- The **tracker, replay, and `/api/send`** endpoints are *bypassed* so
  anonymous visitors can still beacon. Without the bypass, every page
  view on a tablet visitor would hit an Access login page and fail.

## DNS / split-horizon

blocky returns `192.168.68.17` for every `*.imapps.uk` host (LAN +
tailnet bypass Cloudflare). For `analytics.imapps.uk` we want the LAN
answer to STILL go to Traefik (no `<host>.imapps.uk` LAN proxy), so no
blocky change needed.

## First-boot

1. Provision the DB password:

   ```sh
   dokploy secret umami db_password /dev/stdin    # vaultwarden item `umami.db.password`
   dokploy secret umami db_url /dev/stdin         # postgresql://umami:<pw>@umami-db:5432/umami
   ```

2. Bootstrap the dashboard — login is `admin/umami`, change it
   immediately, store the new password in vaultwarden under
   `umami.admin.password`.

3. Create a "Website" for each consumer:

   - shoppingo: hostname `shoppingo.imapps.uk`, "Enable session
     recording" off until #73 lands, sample rate 0.0
   - jewellery-catalogue: same shape, hostname
     `jewellery-catalogue.imapps.uk`, do not enable until the
     catalogue consent UI exists.

## Upgrade story

`docker.umami.is/umami-software/umami` is pinned by digest; Dependabot
opens a PR whenever upstream publishes a new digest for the same tag.
The companion postgres stays on `postgres:16-alpine`; jump to 17 only
after Umami adds a known-good Postgres 17 image (open question, see
[e86f073](https://github.com/umami-software/umami/pull/EXTERNAL) on
their tracker).
