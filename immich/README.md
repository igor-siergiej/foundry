# Immich

Self-hosted photo/video library (Google Photos replacement). Four containers: `immich-server`,
`immich-machine-learning`, `redis` and a Postgres with the vector extensions Immich needs.

- **Dokploy:** project `nas`, compose `immich` (appName `immich-app-exucge`), source `foundry` repo
  `immich/docker-compose.yml`, branch `main`.
- **Images (pinned):** `ghcr.io/immich-app/immich-server:v3.2.0`,
  `ghcr.io/immich-app/immich-machine-learning:v3.2.0`, `ghcr.io/immich-app/postgres:16-vectorchord0.4.3-pgvectors0.2.0`,
  `docker.io/redis:7-alpine`. Server and ML must stay on the same version; read Immich's release notes for
  breaking changes before bumping (last bump: `v2.7.3 -> v3.2.0`, commit `1ba211e`).

## Ingress

- `immich.imapps.uk` → `immich-server:2283`. The domain (Traefik router, letsencrypt) is configured on the
  Dokploy compose, not in this file — change it with `domain.update`, not a compose edit.
- Cloudflare Access: **bypass**, Immich's own login is the gate. Rate-limit rule on `/auth/login`
  (15 req / 10s / IP). See [homelab.md §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny).
- No host ports.

## Networks

The compose declares only the private `immich` bridge. Dokploy additionally attaches `immich-server` to
`dokploy-network` because it owns the domain (that is how Traefik and Gatus reach it). ML, redis and
Postgres are on `immich` only.

## Storage

| Volume | Mount | Backing | Backed up |
|---|---|---|---|
| `immich-upload` | `/usr/src/app/upload` (rw) | bind `/mnt/tank/shared/immich` (ZFS) | no (lives on the ZFS mirror) |
| `immich-pgdata` | Postgres data | Docker named volume, **host disk** | nightly `pg_dumpall` |
| `model-cache` | ML `/cache` | Docker named volume, host disk | no (re-downloads) |

## Environment

Set in the Dokploy compose env: `DB_PASSWORD` (shared by `immich-server` and `database`). Everything else
(`DB_HOSTNAME`, `DB_USERNAME`, `DB_DATABASE_NAME`, `REDIS_HOSTNAME`, `POSTGRES_*`) is fixed in the compose.

## Deploy / change

Commit + push, then explicit `compose-deploy` — the webhook is unreliable. See
[homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change).

## Health and backups

- Gatus: `Immich (Photos)` → `http://immich-server:2283/api/server/ping`, expects 200
  ([`../monitoring/config/gatus/config.yaml`](../monitoring/config/gatus/config.yaml)).
- Backup: [`../backups/config/immich-pg.sh`](../backups/config/immich-pg.sh) — `pg_dumpall` via
  `docker exec immich-postgres`, gzipped, 7-day retention, restore-drilled weekly into the same Postgres image.
  See [homelab.md §9](../docs/homelab.md#9-backups--restore-drill) and [`../backups/README.md`](../backups/README.md).

## Gotchas

- `immich-pgdata` is the only Immich state on host disk ([`../SECURITY-AUDIT.md`](../SECURITY-AUDIT.md) #5).
  The nightly dump mitigates it; the volume itself is not on tank.
- Because Access is bypassed and LAN/tailnet clients skip Cloudflare entirely, Immich's login is the only
  protection on-LAN, and the `/auth/login` rate limit only applies to remote traffic
  ([homelab.md §2](../docs/homelab.md#2-ingress--dns-how-a-request-reaches-a-service)).
- Backups and the restore drill use the container name `immich-postgres` and user `immich`; renaming either
  in the compose breaks `immich-pg.sh`.
