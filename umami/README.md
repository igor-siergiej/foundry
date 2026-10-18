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
| `umami` | `umami-software/umami@sha256:6cd9d24a…` | 3000 (internal) | Tailscale-only. Reachable only when the request comes from a Tailscale node on this tailnet (admin dashboard + the few times I want to see the analytics from the road). No public exposure. |
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

The shoppingo web app's CSP `connect-src 'self' https://analytics.imapps.uk`
lets the browser reach the tracker. CSP allowlists the hostname; **it
does not bypass Tailscale** — non-tailnet visitors will see a network
error on the beacon, the tracker remains a no-op for them.

## Why Tailscale, not Cloudflare

The public hostname `analytics.imapps.uk` resolves (via Cloudflare
DNS) to `100.79.92.93`, the foundry Tailscale IP. That range
(`100.64.0.0/10`) is CGNAT and not routable on the public internet,
so non-tailnet clients drop at L3 before any HTTP work. The Traefik
listener on this host binds `0.0.0.0:443`, which covers both the LAN
IP (`192.168.68.17`) and the Tailscale IP, so the same compose file
serves tailnet and LAN clients without rebinding. The blocky
`*.imapps.uk → 192.168.68.17` rule still works for tailnet members
who join the LAN through their split-horizon resolver.

Cloudflare Access is intentionally NOT used here:
- Access would need a bypass for `/p`, `/p.js`, `/api/send`,
  `/api/replay` so anonymous beacons (now: tailnet beacons) work.
  Tailscale gives the same outcome by construction.
- The OAuth dance with `mcp-cli cloudflare-api` only needs to happen
  for things that *truly* are public; this isn't.
- The privacy notice for shoppingo is honest: non-tailnet visitors
  generate no data, period.

## DNS / split-horizon

- Cloudflare DNS for `analytics.imapps.uk`: **A 100.79.92.93, grey
  cloud (DNS-only)**. The grey cloud is critical — an orange-cloud
  record would route through Cloudflare's proxy, which would either
  bypass Tailscale's gate (bad: opens the dashboard to the world) or
  fail outright (bad: nothing works). Grey-cloud + the CGNAT IP is
  the whole trick.
- blocky keeps its existing `*.imapps.uk → 192.168.68.17` rule, which
  is what the LAN sees for the analytics host — same as every other
  imapps.uk name. Tailnet clients use Tailscale's `100.79.92.93`
  answer instead, which wins on the source-IP-aware resolver order.
- Cloudflare Tunnel (`infra-cloudflared-tuky7u`) does not need a route
  for `analytics.imapps.uk`. The Cloudflare dashboard only routes the
  hosts you explicitly add, so absence is the default.

## First-boot

1. The DNS record (above) is in Cloudflare.
2. Provision the DB password:
   ```sh
   dokploy compose.update <umami-composeId> --env "UMAMI_DB_PASSWORD=..."
   ```
   (the Dokploy env file is mode 600, decrypted only at deploy
   time). Vaultwarden item `umami.db.password` is the source of
   truth.
3. From any tailnet device, open `https://analytics.imapps.uk/` —
   login is `admin/umami`. Rotate the password immediately and
   store the new one in vaultwarden under `umami.admin.password`.
4. Create a "Website" for each consumer:
   - shoppingo: hostname `shoppingo.imapps.uk`. **Enable session
     recording** OFF. Sample rate stays at 1.0 (server-side). The
     replay-related envs and the `umami.startSessionReplay()` call
     are wired up in `packages/web/src/utils/analytics.ts` but
     never invoked until the consent UX in jott #73 lands.
   - jewellery-catalogue: same shape, hostname
     `jewellery-catalogue.imapps.uk`, do not enable until the
     catalogue consent UI exists.
5. Copy each `websiteId` into the consumer's runtime config:
   shoppingo's live `config.json` is in the Dokploy file mount
   `mountId TI3xnSOEHbIQDSy_d_fMe` (search/replace `websiteId: ""`).

## Upgrade story

`docker.umami.is/umami-software/umami` is pinned by digest; Dependabot
opens a PR whenever upstream publishes a new digest for the same tag.
The companion postgres stays on `postgres:16-alpine`; jump to 17 only
after Umami adds a known-good Postgres 17 image (open question on
their tracker).
