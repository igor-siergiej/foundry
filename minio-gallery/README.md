# minio-gallery (Filestash)

Web S3 browser with image thumbnails and a gallery viewer over the shared MinIO (app image buckets). Runs
[Filestash](https://www.filestash.app/) and talks to MinIO container-to-container at `http://minio:9000`.

- **Dokploy:** project `infra`, compose `minio-gallery` (appName `compose-bypass-back-end-application-glcejz`),
  source `foundry` repo `minio-gallery/docker-compose.yml`, branch `main`.
- **Image:** `machines/filestash:latest` — unpinned ([`../SECURITY-AUDIT.md`](../SECURITY-AUDIT.md) #8).
  Container name `minio-gallery`.

## Ingress

- `minio-gallery.imapps.uk` → `minio-gallery:8334`. Domain is configured on the Dokploy compose with
  **HTTPS off** (no certificate): the Traefik router is on the `web` (HTTP) entrypoint only, with no
  redirect to HTTPS.
- Cloudflare Access: not in the bypass list in
  [homelab.md §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny), so remote traffic falls
  under the wildcard require-email app. Not verified live.
- `APPLICATION_URL=minio-gallery.imapps.uk`. No host ports.

## Networks

`dokploy-network` (external) only — needed to reach `minio:9000` and for Traefik.

## Storage

| Volume | Mount | Backing |
|---|---|---|
| `filestash-state` | `/app/data/state` | Docker named volume, host disk |

Holds Filestash's `config/config.json` (admin password, connection settings), plus its `db`, `log`,
`plugins`, `search`, `certs`.

## Environment

No Dokploy env vars. `APPLICATION_URL` and `CANARY=false` are fixed in the compose. MinIO credentials are not
in the compose; how they are supplied (admin config vs. per-login) was not determined from the repo.

## Deploy / change

Commit + push, then explicit `compose-deploy`
([homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change)).

## Health and backups

- Gatus: `MinIO Gallery` → `http://minio-gallery:8334/healthz`, expects 200.
- Backup: **none** for `filestash-state`. MinIO data itself is also not backed up yet
  ([homelab.md §9](../docs/homelab.md#9-backups--restore-drill)).

## Gotchas

- HTTP-only router: on the LAN path (blocky → Traefik, no Cloudflare) the Filestash admin login crosses the
  network in plaintext. Fix is to move the domain to `websecure` + letsencrypt
  ([`../SECURITY-AUDIT.md`](../SECURITY-AUDIT.md) #11). Remote traffic is TLS via Cloudflare.
- The admin console had no password until 2026-10-14 (SECURITY-AUDIT "Closed 2026-10-14"). If
  `filestash-state` is lost, Filestash starts unconfigured with an open admin console — set the admin password
  immediately after any rebuild.
