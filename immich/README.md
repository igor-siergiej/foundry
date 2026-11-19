# Immich

Self-hosted photo/video library (Google Photos replacement). Four containers: `immich-server`,
`immich-machine-learning`, `redis` and a Postgres with the vector extensions Immich needs.

- **Dokploy:** project `nas`, compose `immich` (appName `immich-app-exucge`), source `foundry` repo
  `immich/docker-compose.yml`, branch `main`.
- **Images (pinned):** `ghcr.io/immich-app/immich-server:v3.4.2`,
  `ghcr.io/immich-app/immich-machine-learning:v3.4.2`, `ghcr.io/immich-app/postgres:16-vectorchord0.4.3-pgvectors0.2.0`,
  `docker.io/redis:7-alpine`. Server and ML must stay on the same version.
  Read Immich's release notes for breaking changes before bumping (last upgrade: `v3.3.5 -> v3.4.2`, 2026-11-19).

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
| `immich-pgdata` | Postgres data | Docker named volume, **host disk** | Immich-managed nightly database dump; pre-upgrade custom dump (see below) |
| `model-cache` | ML `/cache` | Docker named volume, host disk | no (re-downloads) |

## Hardware acceleration (Intel UHD 770)

`/dev/dri` is passed to `immich-server` for video transcoding.

- **Video transcoding:** Quick Sync. The device alone does nothing: the admin setting
  *Video Transcoding → Hardware Acceleration* must be `Quick Sync` with hardware decoding on. That setting
  lives in the Immich DB (`system_metadata` key `system-config`, `ffmpeg.accel = qsv`,
  `ffmpeg.accelDecode = true`), not in this compose, and survives redeploys.
- **Machine learning:** the standard `v3.4.2` image runs CLIP, face recognition and OCR on CPU.
  The `v3.4.2-openvino` image was not published at upgrade time (registry returned `MANIFEST_UNKNOWN`),
  so CPU ML was explicitly selected. This does not disable Quick Sync video transcoding.

## Environment

Set in the Dokploy compose env: `DB_PASSWORD` (shared by `immich-server` and `database`). Everything else
(`DB_HOSTNAME`, `DB_USERNAME`, `DB_DATABASE_NAME`, `REDIS_HOSTNAME`, `POSTGRES_*`) is fixed in the compose.

## Deploy / change

Commit + push, then explicit `compose-deploy` — the webhook is unreliable. See
[homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change).

## Health and backups

- Gatus: `Immich (Photos)` → `http://immich-server:2283/api/server/ping`, expects 200
  ([`../monitoring/config/gatus/config.yaml`](../monitoring/config/gatus/config.yaml)).
- Live nightly database backups: `/mnt/tank/shared/immich/backups/immich-db-backup-*-v3.3.5-pg16.10.sql.gz`
  before the upgrade; these are Immich-managed backups, not proof that the repository's backup timer is installed.
- Pre-upgrade backup: `/mnt/tank/shared/immich-backups/pre-v3.4.2-20261119T232031Z.dump` (`pg_dump -Fc`,
  mode 600). Restored successfully into an isolated container using the production Postgres image:
  **44,336 assets**. Keep this dump for rollback; rolling back images alone does not undo schema migrations.
- Repository backup/restore tooling: [`../backups/config/immich-pg.sh`](../backups/config/immich-pg.sh)
  and [`../backups/README.md`](../backups/README.md).

## Gotchas

- `immich-pgdata` is the only Immich state on host disk ([`../SECURITY-AUDIT.md`](../SECURITY-AUDIT.md) #5).
  The nightly dump mitigates it; the volume itself is not on tank.
- Because Access is bypassed and LAN/tailnet clients skip Cloudflare entirely, Immich's login is the only
  protection on-LAN, and the `/auth/login` rate limit only applies to remote traffic
  ([homelab.md §2](../docs/homelab.md#2-ingress--dns-how-a-request-reaches-a-service)).
- Backups and the restore drill use the container name `immich-postgres` and user `immich`; renaming either
  in the compose breaks `immich-pg.sh`.
