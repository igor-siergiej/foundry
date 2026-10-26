# minio-gallery (Filestash)

Web S3 browser with image thumbnails and a gallery viewer over the app image buckets. Runs
[Filestash](https://www.filestash.app/) and talks to [`../rustfs`](../rustfs) container-to-container at
`http://rustfs:9000`. (The stack keeps its historical name `minio-gallery`: Dokploy compose, container and domain.)

- **Dokploy:** project `infra`, compose `minio-gallery` (appName `compose-bypass-back-end-application-glcejz`),
  source `foundry` repo `minio-gallery/docker-compose.yml`, branch `main`.
- **Image:** `machines/filestash` `:latest` of 2026-10-26, digest-pinned (`@sha256:35e7d1…`, go1.26.10, Debian
  `ca-certificates` 20250419+deb13u1; both reject the eMudhra intermediates). Dependabot bumps the digest.
  Container name `minio-gallery`.

## Ingress

- `minio-gallery.imapps.uk` → `minio-gallery:8334`. Domain is configured on the Dokploy compose with
  **HTTPS on**, certificate `letsencrypt` (since 2026-10-24, SECURITY-AUDIT #11): Dokploy generates the
  `websecure` router with the letsencrypt certresolver and a `web` router that redirects to HTTPS (308).
- Cloudflare Access: not in the bypass list in
  [homelab.md §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny), so remote traffic falls
  under the wildcard require-email app. Not verified live.
- `APPLICATION_URL=minio-gallery.imapps.uk`. No host ports.

## Networks

`dokploy-network` (external) only — needed to reach `rustfs:9000` and for Traefik.

## Storage

| Volume | Mount | Backing |
|---|---|---|
| `filestash-state` | `/app/data/state` | Docker named volume, host disk |

Holds Filestash's `config/config.json` (admin password, connection settings), plus its `db`, `log`,
`plugins`, `search`, `certs`.

## Environment

No Dokploy env vars. `APPLICATION_URL` and `CANARY=false` are fixed in the compose. No S3 connection is
stored: `config.json` only lists the backend types, so the S3 endpoint and keys are typed into the S3 login
form on each sign-in:

| Field | Value |
|---|---|
| Endpoint | `http://rustfs:9000` |
| Region | `us-east-1` |
| Access key / secret | `creds.rustfs-filestash` (RustFS user `filestash`, built-in `readwrite` policy) |

The API rejects requests whose host isn't `APPLICATION_URL` ("Not Allowed"), so test it through
`https://minio-gallery.imapps.uk`, not `minio-gallery:8334`.

## Deploy / change

Commit + push, then explicit `compose-deploy`
([homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change)).

## Health and backups

- Gatus: `Filestash (S3 Gallery)` → `http://minio-gallery:8334/healthz`, expects 200.
- Backup: **none** for `filestash-state`. The RustFS data itself is not backed up yet either
  ([homelab.md §9](../docs/homelab.md#9-backups--restore-drill)).

## Gotchas

- HTTP-only router: on the LAN path (blocky → Traefik, no Cloudflare) the Filestash admin login crosses the
  network in plaintext. Fix is to move the domain to `websecure` + letsencrypt
  ([`../SECURITY-AUDIT.md`](../SECURITY-AUDIT.md) #11). Remote traffic is TLS via Cloudflare.
- The admin console had no password until 2026-10-14 (SECURITY-AUDIT "Closed 2026-10-14"). If
  `filestash-state` is lost, Filestash starts unconfigured with an open admin console — set the admin password
  immediately after any rebuild.
