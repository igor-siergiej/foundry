# Audiobookshelf

Audiobook and podcast server with mobile apps (offline download, progress sync). Rationale is in
[`../jellyfin/COMPANION_APPS.md`](../jellyfin/COMPANION_APPS.md).

- **Dokploy:** project `nas`, compose `audiobookshelf` (appName `nas-audiobookshelf-sgd9sf`), source
  `foundry` repo `audiobookshelf/docker-compose.yml`, branch `main`.
- **Image:** `advplyr/audiobookshelf:latest` — unpinned ([`../SECURITY-AUDIT.md`](../SECURITY-AUDIT.md) #8).

## Ingress

- `audiobookshelf.imapps.uk` → `audiobookshelf:80` (the image's `PORT=80`). Domain is configured on the
  Dokploy compose (letsencrypt).
- Cloudflare Access: **bypass**, Audiobookshelf's own login is the gate
  ([homelab.md §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny)).
- No host ports.

## Networks

Compose declares the private `audiobookshelf` bridge; Dokploy attaches `dokploy-network` for the domain.

## Storage

Both volumes are `external: true` — they must already exist on the host; the compose will not create them.

| Volume | Mount | Backing |
|---|---|---|
| `audiobookshelf-config` | `/config` (`absdatabase.sqlite`) | Docker named volume, host disk |
| `audiobookshelf-books` | `/audiobooks` (**ro**) | bind `/mnt/tank/shared/audiobookshelf` (ZFS; created outside compose) |

To recreate `audiobookshelf-books` on a fresh host:
`docker volume create --driver local --opt type=none --opt o=bind --opt device=/mnt/tank/shared/audiobookshelf audiobookshelf-books`.

## Environment

No secrets or Dokploy env vars. `AUDIOBOOKSHELF_UID` / `AUDIOBOOKSHELF_GID` (`1000`) are set in the compose.

## Deploy / change

Commit + push, then explicit `compose-deploy`
([homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change)).

## Health and backups

- Gatus: `AudiobookShelf` → `http://audiobookshelf:80/ping`, expects 200.
- Backup: **none.** Books are on the ZFS mirror; `audiobookshelf-config` is on host disk and not backed up
  ([homelab.md §9](../docs/homelab.md#9-backups--restore-drill)).

## Gotchas

- The image sets `METADATA_PATH=/metadata`, which this compose does **not** mount. Covers, cache, streams and
  Audiobookshelf's own in-app backups live in the container's writable layer and are lost whenever the
  container is recreated (e.g. a redeploy that pulls a new `:latest`).
- Books are mounted read-only, so in-app actions that write to the library (embedding metadata, uploads) fail.
