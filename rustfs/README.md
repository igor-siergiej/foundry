# rustfs

S3-compatible object storage ([RustFS](https://github.com/rustfs/rustfs), Apache-2.0) for the apps,
replacing [`../minio`](../minio) (`../SECURITY-AUDIT.md` #6, jott #99). Filestash browses it via
[`../minio-gallery`](../minio-gallery). Inventory row: [`homelab.md` §5 `infra`](../docs/homelab.md#infra).

| | |
|---|---|
| Dokploy | project `infra`, compose `rustfs`, path `rustfs/docker-compose.yml` |
| Image | `rustfs/rustfs:1.0.3@sha256:9ca95595…`, digest-pinned; Dependabot bumps it |
| Ports | `9000` S3 API + admin API, `9001` console; **no host publish** |
| Ingress | Dokploy domain `rustfs-console.imapps.uk` → `:9001`. No public DNS record, so LAN/tailnet only. The S3 API has no route; apps use `rustfs:9000` container-to-container |
| Networks | `dokploy-network` (external) |
| Volumes | `rustfs-data` → `/data`, a bind to ZFS dataset `tank/shared/rustfs` (`/mnt/tank/shared/rustfs`), owned `10001:10001` (the image's `rustfs` user) |
| Env (Dokploy) | `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD` (vault `creds.rustfs-root`) |

## Buckets and keys

Each consumer has its own IAM user with a scoped policy; nothing uses root.

| Bucket | User | Policy | Vault item |
|---|---|---|---|
| `shoppingo` | `shoppingo` | `shoppingo-rw`: `s3:*` on `shoppingo` and `shoppingo/*`, plus `s3:ListAllMyBuckets` (the api-utils `ping()` calls `listBuckets`) | `creds.rustfs-shoppingo` |
| all | `filestash` | built-in `readwrite` | `creds.rustfs-filestash` |

`jewellery-catalogue` stays on MinIO until it moves to its in-memory image store; it is not migrated.

Admin: the console at `https://rustfs-console.imapps.uk/rustfs/console/` (the bare `/` returns 403), logging in
with `creds.rustfs-root`. Or `mc`, which speaks the RustFS admin API for users and policies. `minio/mc` is
no longer published, but the pinned MinIO image ships `mc`:

```sh
docker run --rm --network dokploy-network -e U -e P --entrypoint sh \
  minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e -c \
  'mc alias set r http://rustfs:9000 "$U" "$P" >/dev/null && mc admin user list r'
```

## Migration from MinIO (2026-10-18)

`mc mirror` from `minio/shoppingo` (read-only user `rustfs-migration`) into `rustfs/shoppingo` (user
`shoppingo`): 1,230 objects, 140,914,837 bytes. `mc stat --recursive` on both sides matched per key on
size, ETag, content type and user metadata. shoppingo-api's Dokploy env was switched to
`BUCKET_ENDPOINT=rustfs:9000` with the `shoppingo` key, then a second mirror pass found no new objects.
Rollback: [`../minio/README.md`](../minio/README.md#rollback-shoppingo--minio).

## Deploy / change

Commit + push, then `compose-deploy`. See [`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change).
A fresh host needs the dataset first:
`zfs create tank/shared/rustfs && chown 10001:10001 /mnt/tank/shared/rustfs`.

## Health / monitoring

- Container healthcheck: `curl http://127.0.0.1:9000/health/ready`.
- Gatus: `RustFS (Storage)` → `http://rustfs:9000/health/ready` (group Storage).
- `/minio/health/live` and `/minio/health/ready` also exist as MinIO-compatible aliases.
- Logs: the image writes `/logs/rustfs.log` inside the container (lost on recreate);
  `RUSTFS_OBS_LOG_STDOUT_ENABLED=true` mirrors them to stdout, so `docker logs rustfs` and Loki have them.

## Backups

Not backed up by `backups/` yet. The data is on the ZFS mirror, which only covers the loss of one drive.
