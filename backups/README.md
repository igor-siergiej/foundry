# Foundry backup & restore-drill suite

Nightly backups of every stateful service to `/mnt/tank/shared/backups/<service>/`,
plus a weekly restore drill that pulls the newest dump into a throwaway
container and runs a sanity query.

The hard rule: a backup is only a backup if you've actually restored it.
The drill catches schema-drift, version skew and stale encryption keys
that no `du`/`stat` can see.

## Inventory

| Service            | Backup config                  | Strategy                                    | Default retention |
|--------------------|--------------------------------|---------------------------------------------|-------------------|
| mongodb            | `config/mongodb.sh`            | `mongodump --gzip` via docker exec          | 7 nightly         |
| immich Postgres    | `config/immich-pg.sh`          | `pg_dumpall` via docker exec, gzipped       | 7 nightly         |
| vaultwarden        | `config/vaultwarden.sh`        | SQLite `.backup` + RSA key, tar'd           | 14 nightly        |
| navidrome          | `config/navidrome.sh`          | SQLite `.backup` of `navidrome.db`          | 7 nightly         |
| homeassistant      | `config/homeassistant.sh`      | tar of `/mnt/tank/shared/homeassistant/config` (excludes deps, recorder DB) | 14 nightly |
| gtnh               | `config/gtnh.sh`               | `rcon-cli save-all` then alpine sidecar tar | 7 nightly         |

### Not yet backed up (follow-up cards)

- **rustfs** (tandra + jewellery-catalogue images, ~150 MB) — S3 mirror
  (`rc`) to `/mnt/tank/shared/backups/rustfs/` with a read-only IAM user;
  restore drill is a diff against prod.
- **opensearch** — derived from mongo (tandra recipe index), can rebuild
  from mongo via `scripts/reindex.sh`; consider a periodic rebuild rather
  than a binary backup.
- **jellyfin / audiobookshelf / monitoring / mixtape / immich ML model
  cache / resilio-sync** — metadata-only SQLite DBs. Worth backing up only
  if rebuild-from-scratch is too painful; tracked in
  `docs/homelab.md` §10.
- **Vaultwarden icon_cache** — included already via the rsync into the
  vaultwarden staging; covered.

## Deploy

```sh
# Render /etc/foundry/backup.env once (Discord webhook URL + any
# service-specific creds that aren't already in Dokploy env).
sudo install -m 0600 /dev/null /etc/foundry/backup.env
# edit DISCORD_WEBHOOK_URL=...  MONGO_ROOT_USER=...  MONGO_ROOT_PASSWORD=...

sudo systemctl link backups/systemd/foundry-backup.service \
                    backups/systemd/foundry-backup.timer \
                    backups/systemd/foundry-restore-drill.service \
                    backups/systemd/foundry-restore-drill.timer \
                    backups/systemd/foundry-stale-check.service \
                    backups/systemd/foundry-stale-check.timer \
                    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now foundry-backup.timer \
                          foundry-restore-drill.timer \
                          foundry-stale-check.timer
```

`/etc/foundry/backup.env` is **mode 600, root**, and holds only what
Dokploy doesn't already have: the Discord webhook URL and the Mongo root
credentials that `mongodb.sh` needs. The env file does **not** carry a
`BW_SESSION` — the routine reads `MONGO_ROOT_USER`/`MONGO_ROOT_PASSWORD`
directly because they live in Dokploy env, not Vaultwarden.

If you'd rather pull `MONGO_ROOT_USER`/`MONGO_ROOT_PASSWORD` from
Vaultwarden too, follow the dotfiles `docs/secrets.md` pattern:
`bw-render-template "foundry.backup.env" <template> /etc/foundry/backup.env`
in a single command — never export `BW_SESSION` from the timer.

## Manual run

```sh
sudo systemd-run -E DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/... \
                 /home/home/imapps/foundry/backups/bin/backup.sh

sudo systemd-run -E DISCORD_WEBHOOK_URL=... \
                 /home/home/imapps/foundry/backups/bin/restore-drill.sh

sudo systemd-run -E DISCORD_WEBHOOK_URL=... \
                 /home/home/imapps/foundry/backups/bin/stale-check.sh
```

## Adding a service

Drop a `config/<service>.sh` file with two functions:

```sh
do_backup()        { ensure_dir "$DEST"; ... }
do_restore_drill() { ... }
```

Required globals (per-service config):
- `SERVICE_NAME` — used for `BACKUPS_ROOT/$SERVICE_NAME/` and the lock key.
- `DEST` — usually `$BACKUPS_ROOT/$SERVICE_NAME`.
- `RETENTION_DAYS` — prune cutoff (drill doesn't depend on it).

`lib/common.sh` provides `log_info/log_warn/log_err`, `with_lock`,
`ensure_dir`, `timestamp`, `discord_post`, `retain_dumps`.

## Discord alerts

The same webhook as Gatus / smoke routine (`DISCORD_WEBHOOK_URL`):

- `**Backup failures**` — one per run, lists every service that failed.
- `**Restore-drill failures**` — one per run, lists every service whose
  newest dump could not be restored.
- `**Stale backups**` — one per stale-check tick, lists every service
  whose newest dump is older than 2× its schedule.

Green runs stay silent — exit 0, no message.

## What this is not

- Not off-host. `/mnt/tank/shared/backups` is on the same ZFS mirror as
  the source data; a host-disk loss that kills `/mnt/tank/shared/mongodb`
  also kills `/mnt/tank/shared/backups`. Off-host copy (rclone to
  Backblaze B2 / a friend's box) is a separate card.
- Not encrypted at rest. Vaultwarden's RSA key is in the tarball, so the
  whole vault backup is encrypted by Vaultwarden itself; everything else
  is plaintext on tank. Acceptable because tank is the same trust domain
  as prod.
- Not app-aware. We're using `mongodump`/`pg_dumpall`/`sqlite .backup`,
  not per-app logical dumps. Faster and more standard, but if an app
  uses an obscure SQLite extension (e.g. FTS5), the drill container
  needs the matching image.