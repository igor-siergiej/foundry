# minio

S3-compatible object storage, **being replaced by [`../rustfs`](../rustfs)** (jott #99). Since 2026-10-18
it only serves `jewellery-catalogue` (its 18 images), which stays here until that app moves to its
in-memory image store; then this stack is stopped and removed. The `shoppingo` bucket here is a stale
copy from the cutover, kept for rollback. Inventory row: [`homelab.md` §5 `infra`](../docs/homelab.md#infra).

| | |
|---|---|
| Dokploy | project `infra`, compose `minio` (`infra-minio-dk6zsf`), path `minio/docker-compose.yml` |
| Image | `minio/minio@sha256:14cea493…` — the locally cached `RELEASE.2025-09-07T16-13-09Z`, digest-pinned 2026-10-18 because upstream stopped publishing images (`../SECURITY-AUDIT.md` #6). Never `docker image prune -a` while this stack exists |
| Command | `server /data --console-address ":9001"` |
| Ports | `9000` S3 API, `9001` console; **no host publish** (dropped 2026-10-10) |
| Ingress | Dokploy domains: `minio.imapps.uk` → `:9000`, `minio-console.imapps.uk` → `:9001`, HTTPS/letsencrypt. Access: wildcard require-email app (remote only); on LAN/tailnet MinIO's own root login is the only gate |
| Networks | `dokploy-network` (external). Apps use `minio:9000` container-to-container, never `*.imapps.uk` ([`homelab.md` §2](../docs/homelab.md#2-ingress--dns-how-a-request-reaches-a-service)) |
| Volumes | `minio-data` → `/data`, declared `external: true`; live it is a bind to `/mnt/tank/shared/minio` (`docker volume inspect minio-data`), created outside this compose file |
| Env (Dokploy) | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` |

## Deploy / change

Commit + push, then `compose-deploy` — [`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change).
Because the volume is external, `docker compose down -v` will not delete it, and a fresh host needs
`minio-data` created (bind to `/mnt/tank/shared/minio`) before the first deploy.

## Health / monitoring

- Gatus: `MinIO (Storage)` → `http://minio:9000/minio/health/live` (group Storage).
- No container healthcheck, no Prometheus scrape job.

## Backups

Not backed up by `backups/` (`mc mirror` of a large bucket set is still a follow-up,
[`homelab.md` §9](../docs/homelab.md#9-backups--restore-drill)). The data is on the ZFS mirror, which
covers a single-drive loss only.

## Gotchas

- No upstream image updates since late 2025 (`../SECURITY-AUDIT.md` #6); RustFS is the replacement.
- Older docs list `minio-data` as host-disk; that is stale since the 2026-10 hardening.
- New services that need S3 use `rustfs:9000`, not this.
- IAM users added for the cutover: `rustfs-migration` (policy `shoppingo-readonly`, vault
  `creds.minio-migration`), used by `mc mirror`. Drop it with the stack.

## Rollback (shoppingo → MinIO)

Put shoppingo-api's Dokploy env back to `BUCKET_ENDPOINT=minio:9000` with the keys in vault
`creds.minio-shoppingo-rollback`, then redeploy it. First mirror anything written since the cutover
back from RustFS (`mc mirror r/shoppingo m/shoppingo`).
