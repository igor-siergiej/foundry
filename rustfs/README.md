# rustfs

S3-compatible object storage ([RustFS](https://github.com/rustfs/rustfs), Apache-2.0) for the apps.
Filestash browses it via [`../minio-gallery`](../minio-gallery). Inventory row:
[`homelab.md` §5 `infra`](../docs/homelab.md#infra).

| | |
|---|---|
| Dokploy | project `infra`, compose `rustfs` (`infra-rustfs-3v1saj`), path `rustfs/docker-compose.yml` |
| Image | `rustfs/rustfs:1.0.3@sha256:9ca95595…`, digest-pinned; Dependabot bumps it |
| Ports | `9000` S3 API + admin API, `9001` console; **no host publish** |
| Ingress | Dokploy domain `rustfs-console.imapps.uk` → `:9001`. No public DNS record, so LAN/tailnet only. The S3 API has no route; apps use `rustfs:9000` container-to-container |
| Networks | `dokploy-network` (external) |
| Volumes | `rustfs-data` → `/data`, a bind to ZFS dataset `tank/shared/rustfs` (`/mnt/tank/shared/rustfs`, no `sharenfs`), owned `10001:10001` (the image's `rustfs` user) |
| Env (Dokploy) | `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD` (vault `creds.rustfs-root`) |

## Buckets and keys

Each consumer has its own IAM user with a scoped policy; nothing uses root. App policies also grant
`s3:ListAllMyBuckets`, because the api-utils `ObjectStoreConnection.ping()` calls `listBuckets`.

| Bucket | User | Policy | Vault item |
|---|---|---|---|
| `tandra` | `tandra` | `tandra-rw`: `s3:*` on `tandra`, `tandra/*` | `creds.rustfs-tandra` |
| `jewellery-catalogue` | `jewellery-catalogue` | `jewellery-catalogue-rw`: `s3:*` on `jewellery-catalogue`, `jewellery-catalogue/*` | `creds.rustfs-jewellery-catalogue` |
| all | `filestash` | built-in `readwrite` | `creds.rustfs-filestash` |

Each app gets `BUCKET_ENDPOINT=rustfs:9000`, `BUCKET_NAME`, `BUCKET_ACCESS_KEY`, `BUCKET_SECRET_KEY`
in its Dokploy env.

## Admin

Console: `https://rustfs-console.imapps.uk/rustfs/console/` (the bare `/` returns 403), login `creds.rustfs-root`.

CLI: RustFS's `rc` (users, policies, buckets, objects):

```sh
docker run --rm --network dokploy-network -e U -e P --entrypoint sh \
  rustfs/rc:v0.1.36@sha256:ab024bfebee49a750ce886b4c70963ccd9ddaa03f491704a90710641d7a26699 -c \
  'rc alias set r http://rustfs:9000 "$U" "$P" >/dev/null && rc admin user list r && rc bucket list r/'
```

## History

Data imported 2026-10-18 from the previous object store (jott #99, `../SECURITY-AUDIT.md` #6): the app
now called tandra 1,230 objects / 140,914,837 B and jewellery-catalogue 18 objects / 10,449,871 B, each
matched per key on size, ETag, content type and user metadata before the apps' env was switched.

## Deploy / change

Commit + push, then `compose-deploy`. See [`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change).
A fresh host needs the dataset first:
`zfs create tank/shared/rustfs && chown 10001:10001 /mnt/tank/shared/rustfs`.

## Health / monitoring

- Container healthcheck: `curl http://127.0.0.1:9000/health/ready`.
- Gatus: `RustFS (Storage)` → `http://rustfs:9000/health/ready` (group Storage).
- Logs: the image writes `/logs/rustfs.log` inside the container (lost on recreate);
  `RUSTFS_OBS_LOG_STDOUT_ENABLED=true` mirrors them to stdout, so `docker logs rustfs` and Loki have them.

## Backups

Not backed up by `backups/` yet. The data is on the ZFS mirror, which only covers the loss of one drive.
