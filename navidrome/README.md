# Navidrome

Music streaming server (Subsonic-compatible API, web UI). Libraries are per user: one folder per user under
the music root, populated mostly by Mixtape.

- **Dokploy:** project `nas`, compose `navidrome` (appName `nas-navidrome-9qcf6b`), source `foundry` repo
  `navidrome/docker-compose.yml`, branch `main`.
- **Image:** `deluan/navidrome` 0.63.2, digest-pinned (`@sha256:901293…`, go1.26.5); Dependabot bumps the digest.
  Still trusts the eMudhra intermediates (CVE-2026-111943): the newest release, 0.64.2, is go1.27.1, so it
  stays put until a release is built with go1.26.10 / go1.27.3 or later.

## Ingress

- `navidrome.imapps.uk` → `navidrome:4533`. Domain is configured on the Dokploy compose (letsencrypt).
- Cloudflare Access: **bypass**, Navidrome's own login is the gate
  ([homelab.md §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny)). Subsonic clients need
  the bypass to work remotely.
- No host ports. `ND_BASEURL` is empty (served at the host root).

## Networks

Compose declares the private `navidrome` bridge; Dokploy attaches `dokploy-network` for the domain.

## Storage

| Volume | Mount | Backing |
|---|---|---|
| `navidrome-config` | `/data` (`navidrome.db`, cache) | Docker named volume, host disk |
| `navidrome-music` | `/music` (**ro**) | bind `/mnt/tank/shared/navidrome` (ZFS) |

The same host path is mounted **read-write** at `/music` by Mixtape, which writes mp3s into
`/music/<libraryFolder>/` (currently `igor/`, `mari/`). See [`../mixtape/README.md`](../mixtape/README.md).

## Environment

No secrets or Dokploy env vars. `ND_LOGFORMAT=json`, `ND_LOGFRAME=false`, `ND_BASEURL=""` are fixed in the
compose.

## Users and libraries

Per user: create a Navidrome user, add a library at `/music/<libraryFolder>`, assign it to that user, and add
the matching entry to Mixtape's `USER_LIBRARIES`. Procedure is in the mixtape repo README ("Navidrome
per-user setup").

## Deploy / change

Commit + push, then explicit `compose-deploy`
([homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change)).

## Health and backups

- Gatus: `Navidrome (Music)` → `http://navidrome:4533/health`, expects 200.
- Backup: [`../backups/config/navidrome.sh`](../backups/config/navidrome.sh) — SQLite `.backup` of
  `/data/navidrome.db` via `docker exec navidrome`, 7-day retention, weekly integrity drill. Music files are
  not backed up (already on the ZFS mirror).

## Gotchas

- The backup script needs `sqlite3` inside the `navidrome` container and the container name `navidrome`; an
  upstream image change that drops `sqlite3` breaks the nightly backup (check before merging a digest bump).
- A local dev instance (`dev-navidrome`, from `utils/docker`) also exists on this host bound to `127.0.0.1`;
  it is not production ([homelab.md §5](../docs/homelab.md#5-projects--services-dokploy-inventory)).
