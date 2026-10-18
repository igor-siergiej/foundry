# Mixtape (production deploy)

Production compose for [Mixtape](https://github.com/igor-siergiej/mixtape): paste a YouTube link, get tagged
mp3s in your Navidrome library (audio mode) or an mp4 in Jellyfin's `YouTube/` folder (video mode).
Multi-user via kivo auth.

## How this relates to the mixtape repo

- **App code, images, CI** live in `/home/home/imapps/mixtape` (`github.com/igor-siergiej/mixtape`). Its CI
  `build-publish` job pushes `docker.io/igurusama/imapps:mixtape-api-latest` and `:mixtape-web-latest`, then
  its `deploy` job POSTs the Dokploy compose webhook (`DEPLOY_URL` secret, with an `X-GitHub-Event: push`
  header so Dokploy accepts the branch, and CF Access service-token headers).
- **This file** is what Dokploy actually runs. It pulls those images (`pull_policy: always`, so a redeploy
  always picks up the new `:latest`). It does not build anything.
- The mixtape repo's own `docker-compose.yml` is for local builds (`build:` from `Dockerfile.api` /
  `Dockerfile.web`, host port 3000, NFS volumes) and is **not** used in production. Its README "Deployment
  (Dokploy)" section describes the older shape; this file wins.
- Planned: replace this compose with two image-based Dokploy applications, then delete this directory. Plan and
  the web↔api routing/SSE caveat are in the mixtape repo's
  `docs/migrate-to-dokploy-apps.md`. Not done as of this README.

## Dokploy

Project `nas`, compose `mixtape` (composeId `fwoqSTtJyMdZWpHbDfu37`, appName
`compose-parse-1080p-microchip-k6mk71`), source `foundry` repo `mixtape/docker-compose.yml`, branch `main`.

## Services

| Service | Container | Image | Port |
|---|---|---|---|
| `api` | `mixtape-api` | `docker.io/igurusama/imapps:mixtape-api-latest` | 3001 (internal) |
| `web` | `mixtape-web` | `docker.io/igurusama/imapps:mixtape-web-latest` | 3000 (`expose`, no host port) |

`web` is nginx serving the SPA and proxying `/api` to `http://api:3001` over the `mixtape` network (see the
mixtape repo's `Dockerfile.web`).

## Ingress

- `mixtape.imapps.uk` → `web:3000` (Dokploy domain on the compose, letsencrypt, path `/`). `api` has no route
  of its own; it is reached through `web`'s `/api` proxy.
- Cloudflare Access: **bypass**; kivo login is the gate
  ([homelab.md §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny)).

## Networks

- `mixtape` (bridge): `api` ↔ `web`.
- `dokploy-network` (external): `api` joins it to reach the shared `mongodb:27017` directly (commit
  `398caa0`; previously it went via `infra-mongodb.imapps.uk` and broke on a DHCP lease change). Dokploy also
  attaches `web` to it for the domain.

## Storage

| Volume | Mount (`api`) | Backing | Shared with |
|---|---|---|---|
| `mixtape-music` | `/music` (rw) | bind `/mnt/tank/shared/navidrome` (ZFS) | Navidrome, read-only |
| `mixtape-video` | `/videos` (rw) | bind `/mnt/tank/shared/jellyfin/media` (ZFS) | Jellyfin, read-write |

Audio lands in `/music/<libraryFolder>/` (per `USER_LIBRARIES`), video in `/videos/YouTube/`.

`web` also mounts a Dokploy file mount, `files/config.json` → `/usr/share/nginx/html/config.json` (ro). It sets
the runtime `AUTH_URL` for the frontend (currently `https://kivo.imapps.uk`); edit it in the Dokploy compose's
Mounts, not in git. The host path in the compose embeds the appName, so recreating the Dokploy compose
breaks it.

## Environment

Dokploy compose env (values in Dokploy, not here): `AUTH_URL` (kivo base URL), `USER_LIBRARIES` (JSON,
case-sensitive kivo username → library folder), `CONNECTION_URI`, `DATABASE_NAME` (scoped mixtape user on the
shared mongo). Fixed in the compose: `PORT=3001`, `MUSIC_ROOT=/music`, `JELLYFIN_ROOT=/videos`, `MIX_CAP=50`.
The api crash-loops on startup without `JELLYFIN_ROOT` (v1.5.0+, commit `5c55ea7`).

Per the migration handoff doc the Dokploy env still carries unused `JWT_SECRET` / `USERS_JSON`; not verified
(env values are redacted via the MCP).

## Deploy / change

- **App code change:** merge to mixtape `main`; its CI builds, pushes and fires the webhook. If the webhook
  does not fire, run `compose-deploy` on this compose.
- **Compose change (this file):** commit + push to foundry, then explicit `compose-deploy`
  ([homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change)). Any foundry push can
  also trigger a mixtape redeploy via `autoDeploy`.

## Health, smoke, backups

- Gatus: `Mixtape (API)` → `http://mixtape-api:3001/api/health` (200 and `status == healthy`);
  `Mixtape (Web)` → `http://mixtape-web:3000/` (200).
- Nightly prod smoke: mixtape is one of the four apps in
  [`../smoke/bin/run-smoke.sh`](../smoke/bin/run-smoke.sh) (`smoke.mixtape.account` in Vaultwarden). See
  [`../smoke/README.md`](../smoke/README.md).
- Backup: no mixtape-specific job. Job history lives in the shared mongo, covered by the nightly mongodb dump;
  the downloaded media sits on the ZFS mirror
  ([homelab.md §9](../docs/homelab.md#9-backups--restore-drill)).

## Gotchas

- Adding a user touches three systems: kivo (register), Navidrome (user + library at
  `/music/<libraryFolder>`), and `USER_LIBRARIES` here. See the mixtape repo README "Navidrome per-user setup".
- `pull_policy: always` is load-bearing: without it Dokploy reuses the stale local `:latest` and never ships
  new code.
