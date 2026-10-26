# Jellyfin

Video streaming server (films, TV, GoPro footage, and Mixtape's YouTube downloads). Client options and the
original music/audiobook companion plan are in [`COMPANION_APPS.md`](./COMPANION_APPS.md) — its YAML
snippets predate the current stacks (host ports, shared `jellyfin-media` volume); the live Navidrome and
Audiobookshelf definitions are in [`../navidrome/`](../navidrome/) and [`../audiobookshelf/`](../audiobookshelf/).

- **Dokploy:** project `nas`, compose `jellyfin` (appName `nas-jellyfin-dfityv`), source `foundry` repo
  `jellyfin/docker-compose.yml`, branch `main`.
- **Image (pinned):** `jellyfin/jellyfin:12.3@sha256:2038fe…` (2026-10-26, from `10.11.11`). Its Debian
  `ca-certificates 20250419+deb13u1` rejects the compromised eMudhra intermediates; .NET uses the OS bundle.

## Ingress

- `jellyfin.imapps.uk` → `jellyfin:8096`. Domain is configured on the Dokploy compose (letsencrypt), not in
  this file.
- Cloudflare Access: **bypass**, Jellyfin's own login is the gate
  ([homelab.md §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny)).
- No host ports.

## Networks

Compose declares the private `jellyfin` bridge; Dokploy attaches `dokploy-network` for the domain.

## Storage and devices

| Volume | Mount | Backing |
|---|---|---|
| `jellyfin-config` | `/config` (`JELLYFIN_DATA_DIR`) | Docker named volume, host disk |
| `jellyfin-cache` | `/cache` (`JELLYFIN_CACHE_DIR`) | Docker named volume, host disk |
| `jellyfin-media` | `/media` (**rw**) | bind `/mnt/tank/shared/jellyfin/media` (ZFS) |

Library folders under `/media`: `Movies`, `TV Shows`, `GOPRO`, `YouTube`. `YouTube/` is written by
Mixtape, which binds the same host path as its `/videos` ([`../mixtape/README.md`](../mixtape/README.md)).

`/dev/dri` is passed through for hardware transcoding.

## Environment

No secrets or Dokploy env vars. `JELLYFIN_DATA_DIR` and `JELLYFIN_CACHE_DIR` are fixed in the compose.

## Deploy / change

Commit + push, then explicit `compose-deploy`
([homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change)). Read Jellyfin's
release notes before a version bump; config DB migrations are one-way, so snapshot the config volume first
(with `jellyfin` stopped):

```sh
docker run --rm -v nas-jellyfin-dfityv_jellyfin-config:/c:ro -v /mnt/tank/shared/backups:/b alpine \
  tar -czf /b/jellyfin-config-pre-<version>-<date>.tar.gz -C /c .
```

Rollback = restore that tarball into the volume and redeploy the previous tag. 12.x needs a full library scan
after an upgrade from 10.x to restore auto-resolved alternate versions; the scheduled `Scan Media Library`
task (every 12h) covers it.

## Health and backups

- Gatus: `Jellyfin (Media)` → `http://jellyfin:8096/health`, expects 200.
- Backup: **none.** Media is on the ZFS mirror; `jellyfin-config` (users, watch state, library DB) is on host
  disk and not backed up — listed as "not yet backed up" in
  [homelab.md §9](../docs/homelab.md#9-backups--restore-drill).

## Gotchas

- The media mount is read-write because Mixtape shares it; Jellyfin itself can also modify/delete media
  (e.g. via the UI's delete action).
- Access bypass + LAN split-horizon means Jellyfin's login is the only gate on-LAN.
