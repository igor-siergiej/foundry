# Umami — self-hosted analytics

## Why

Tandra's only telemetry used to be the JSON `POST /api/logs` route through
Loki (operational logs in [`docs/homelab.md` §10](../docs/homelab.md)).
That doesn't tell us whether people are actually using Discover / the
use-up pantry search or whether the recipe-import path is fine. With
~50 active shoppers across all features, hosted PostHog is overkill (and
officially unsupported on a 4-vCPU / shared-RAM box); the Umami image
fits easily and is what [jott #72 / foundry #101] landed on.

Decided **2026-10-16**; dashboard made tailnet/LAN-only 2026-10-18; tracker
made public on the app's own host 2026-10-22 (tandra jott #138). One
instance, one "website" per consumer app — Tandra first,
jewellery-catalogue next, sentinel uses Loki only.

## Topology

| Service | Image | Port | Notes |
|---|---|---|---|
| `umami` | `umami-software/umami@sha256:6cd9d24a…` | 3000 (internal) | Dashboard: `analytics.imapps.uk`, LAN/tailnet-only (no public DNS record). Tracker: two public paths on `app.tandra.uk` (below). |
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

## Public tracker surface

Every visitor to the Tandra app (home Wi-Fi, mobile data, anywhere) must be
able to load the tracker, and the Umami admin UI must not be public. So the
tracker is served **same-origin on the app's host**, not from
`analytics.imapps.uk`. The `umami-tracker` Traefik router in
`docker-compose.yml` matches exactly:

| Public URL | Upstream | What |
|---|---|---|
| `https://app.tandra.uk/pulse/p.js` | `umami:3000/p.js` | tracker script |
| `https://app.tandra.uk/pulse/p` | `umami:3000/p` | collect endpoint (page views, events) |
| `https://app.tandra.uk/pulse/recorder.js` | `umami:3000/recorder.js` | heatmap / replay recorder (rrweb, ~57 KB gzipped) |
| `https://app.tandra.uk/pulse/api/record` | `umami:3000/api/record` | recorder ingest; Umami rejects posts without the tracker's session token (`x-umami-cache`) |
| `https://app.tandra.uk/pulse/api/websites/<id>/recorder` | same path, prefix stripped | recorder settings, only for the Tandra (`b07e19e2-…`) and Tandra site (`dfe972ee-…`) website ids (read-only; Umami serves it unauthenticated) |

A `stripprefix` middleware drops `/pulse`. Any other `/pulse/*` path (login,
`/api/*`) is not matched and falls through to `tandra-web`'s SPA, so the
dashboard and its API stay off the internet. The router rule is longer than
`tandra-web`'s `Host(app.tandra.uk)`, so Traefik's rule-length priority
picks it first. Traffic arrives through the Cloudflare tunnel like the rest
of `app.tandra.uk` (no Access app on the `tandra.uk` zone), so no Cloudflare
change was needed.

Why same-origin and not the dashboard host: until 2026-10-22 the app loaded
`https://analytics.imapps.uk/p.js`. That host only resolves via blocky, so
off-network visitors got NXDOMAIN (Umami only ever recorded the household),
and on the home network a public origin fetched a script from a private IP,
which is what Chrome's Local Network Access prompt fires on. The path prefix
is `/pulse` because it matches no generic EasyList / EasyPrivacy rule
(checked 2026-10-22); `/stats/`, `/metrics/` and `/beacon/` all do.

The tracker derives the collect URL from its own `src` (`/pulse/p.js` →
`/pulse/p`), so Tandra's runtime config only sets
`analytics.host = "https://app.tandra.uk/pulse"`.

### Heatmaps and replay

The recorder (added 2026-10-22) fetches its settings from the website's
`/recorder` endpoint and only records what they turn on. The Tandra website
has **heatmaps on** (click positions and scroll depth, no page content) and
**session replay off**; set in the dashboard under the website's settings.
It needs the tracker's session token, so it records nothing when the tracker
is opted out (`localStorage['umami.disabled']`). Turning replay on is gated
on the consent UI (tandra jott #116), not on routing: the ingest path is
shared.

## Dashboard access: Tailscale split-DNS, no public DNS

A public hostname (`analytics.imapps.uk`) is the right UX (a branded
name beats `<node>.ts.net`) but it doesn't have to be reachable from
the public internet. The trick is **Tailscale's split-DNS**:

- The Tailscale admin console has a nameserver route for `imapps.uk`
  pointing at the foundry blocky resolver (192.168.68.17 via the existing
  Tailscale subnet route).
- Tailnet members asking for `analytics.imapps.uk` get the blocky
  answer (the LAN IP `192.168.68.17`, which the subnet route
  sends over the tailnet anyway).
- LAN clients (anyone on the home network) get the same blocky
  answer and connect over the LAN.
- Everyone else hits their upstream resolver, which returns NXDOMAIN
  because there is no public record.

### Split-DNS setup (one-time, in the Tailscale admin console)

1. **Settings → Nameservers → Add nameserver route**:
   - **Domain**: `imapps.uk`
   - **Nameserver**: `192.168.68.17` (the foundry LAN IP, already
     advertised by foundry's Tailscale subnet route).
   - **Use as DNS resolver for**: `Tailnet + subnet routes`
2. Save. Tailscale pushes the resolver to every member of the tailnet;
   no client-side work.
3. Verify from a tailnet device:
   ```sh
   dig analytics.imapps.uk @100.100.100.100 +short
   # expect 192.168.68.17
   dig analytics.imapps.uk @1.1.1.1 +short
   # expect nothing (NXDOMAIN)
   ```

## First-boot

1. Tailscale split-DNS is in place (above).
2. Provision the DB password:
   ```sh
   dokploy compose.update <umami-composeId> --env "UMAMI_DB_PASSWORD=..."
   ```
   (the Dokploy env file is mode 600, decrypted only at deploy
   time). Vaultwarden item `umami.db.password` is the source of truth.
3. From any tailnet device, open `https://analytics.imapps.uk/` —
   login is `admin/umami`. Rotate the password immediately and store
   the new one in vaultwarden under `umami.admin.password`.
4. Create a "Website" for each consumer:
   - Tandra (the app): domain `app.tandra.uk` (website id
     `b07e19e2-6c29-432f-a4f1-fe280b7f3794`). Heatmaps on; session replay
     OFF until the consent UI (tandra jott #116) lands.
   - Tandra site (the `tandra.uk` landing site, `tandra-site` repo): domain
     `tandra.uk` (website id `dfe972ee-98e3-4732-b9b0-2427252f1435`), split
     from the app's website on 2026-10-22. Same settings. It loads the
     tracker cross-origin from `app.tandra.uk/pulse`; Umami allows any
     origin on the collect and record endpoints. Visits before the split
     are in the app's website under hostname `tandra.uk`.
   - jewellery-catalogue: same shape, domain
     `jewellery-catalogue.imapps.uk`, do not enable until the
     catalogue consent UI exists.
5. Copy each `websiteId` into the consumer's runtime config. Tandra's live
   `config.json` is the Dokploy file mount `DkkAGZ2b5-KmuKt1qxHwg` on
   `tandra-web` (mounted at `/usr/share/nginx/html/config.json`):
   ```json
   { "analytics": { "host": "https://app.tandra.uk/pulse", "websiteId": "…", "enabled": true } }
   ```

## Verifying

```sh
# Public path, as any off-network client sees it (app.tandra.uk always
# resolves to Cloudflare, so this goes edge → tunnel → Traefik):
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' https://app.tandra.uk/pulse/p.js
# expect: 200 application/javascript
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' https://app.tandra.uk/pulse/api/auth/verify
# expect: 200 text/html (the SPA shell, not Umami)
```

Then load the app off-network and check the Tandra website's Realtime view.

## Upgrade story

`docker.umami.is/umami-software/umami` is pinned by digest; Dependabot
opens a PR whenever upstream publishes a new digest for the same tag.
The companion postgres stays on `postgres:16-alpine`; jump to 17 only
after Umami adds a known-good Postgres 17 image (open question on
their tracker).
