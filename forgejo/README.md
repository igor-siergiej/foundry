# Forgejo — self-hosted git + Actions runner

## What / where

| Service | Image | Port | Notes |
|---|---|---|---|
| `forgejo` | `data.forgejo.org/forgejo/forgejo:17.0.1@sha256:fcd19ff4…` | 3000 (internal) | `git.imapps.uk`, currently private (Tailscale/LAN), with valid HTTPS. SSH disabled, registration disabled, SQLite. Public Cloudflare exposure is approved but blocked on Cloudflare OAuth authorization; it is not public yet. |
| `dind` | `data.forgejo.org/oci/docker:29-dind@sha256:7bf70dcb…` | 2375 (private `forgejo` network only) | Privileged Docker daemon for CI jobs. Plain TCP is fine: never published, not on `dokploy-network`, and job containers get no docker access (`docker_host: "-"`). |
| `runner` | `data.forgejo.org/forgejo/runner:13.2.1@sha256:568cea8c…` | — | Label `ubuntu-latest` (`ghcr.io/catthehacker/ubuntu:act-22.04`), capacity 2, `mem_limit: 2g` (jobs run in dind, limited to 8g/8 cpus each). Config is an inline compose `configs:` entry mounted at `/config.yml`. |

- Data: `forgejo-data` binds `/mnt/tank/shared/forgejo` on the host to `/data`. SQLite is `/mnt/tank/shared/forgejo/gitea/gitea.db`; config is `gitea/conf/app.ini`; bare repositories are `git/repositories/<owner>/<repo>.git`. JWT and Actions signing keys are under `gitea/jwt` and `gitea/actions_id_token`. `git/.ssh` holds SSH client state. Generated push-mirror private keys are encrypted in SQLite, not persistent standalone SSH key files; restoring them also requires the original `app.ini` secret key.
- `dind-data` (`/var/lib/docker`) and `runner-data` (`/data`) are named volumes. DinD images/cache are rebuildable, not part of the Forgejo backup.
- The `git.imapps.uk` → `forgejo:3000` domain is configured in Dokploy, not in this file. Dokploy attaches `dokploy-network` for it. Intended next state: a public Cloudflare route after OAuth authorization is restored, keeping Forgejo login/registration restrictions.
- Gatus: `Forgejo` → `https://git.imapps.uk/api/healthz`. Forgejo has its own user-systemd `forgejo-backup.timer`, daily at 03:30 UTC with persistent catch-up. Its service takes a backup and runs the isolated restore drill before retention. The generic root `foundry-backup` / `foundry-restore-drill` units are not installed; the root `gtnh-backup` unit handles only GregTech.

## Env vars (Dokploy panel; values never in git)

- `RUNNER_SECRET` — 40 hex chars, shared secret the runner registers with.
- `RUNNER_UUID` — derived from the secret (below).

The compose uses `${VAR:?}`, so a deploy without them fails.

```sh
RUNNER_SECRET=$(openssl rand -hex 20)
echo -n "$RUNNER_SECRET" | python3 -c 'import sys,uuid;s=sys.stdin.read();print(uuid.UUID(bytes=s[:16].encode()))'
```

## First-time bring-up

```sh
sudo install -d -o 1000 -g 1000 /mnt/tank/shared/forgejo
# deploy the stack (Dokploy compose-deploy), then:
docker exec -u git forgejo forgejo forgejo-cli actions register --keep-labels --secret "$RUNNER_SECRET"
docker exec -u git forgejo forgejo admin user create --admin --username <name> --email <email> --random-password
```

`--keep-labels` keeps the labels from the runner config instead of overwriting them.
Store the generated admin password in Vaultwarden. Restart the `runner` container after registering if it started first.

API token (for automation), as the admin user:

```sh
docker exec -u git forgejo forgejo admin user generate-access-token --username <name> --token-name <name> --scopes all
```

Prefer narrower scopes (e.g. `write:repository`) where possible, and keep the token in Vaultwarden.

## Upgrade / rollback

Bump the pinned tag **and** digest in `docker-compose.yml`, commit, push, `compose-deploy`.
Forgejo migrates the DB on start and cannot be downgraded: take a manual backup first (`systemctl --user start forgejo-backup.service`), and roll back by restoring it plus the previous pin.
v17.0 is a non-LTS release, EOL 2027-01-28; plan the move to the v19 LTS before then.

After changing the inline `runner-config`, a runner restart alone did not load the new config. Recreate it, then deploy the compose stack through Dokploy:

```sh
docker rm -f forgejo-runner
# Dokploy compose.deploy for composeId 5k8B-0zQyODVVasOc6CCx
```

After rebuilding DinD storage, rebuild jott's local CI image from a jott checkout:

```sh
bash .forgejo/ci/build-ci-image.sh
```

The script targets the Forgejo DinD daemon; rebuilding the runner container does not restore its job images.

## Backup installation (host user `home`, uid 1000)

Run from the foundry checkout containing these changes. The installed copies do
not track later checkout edits; repeat `install` after changing the wrapper,
config or shared library.

```sh
install -d -m 0700 /mnt/tank/shared/forgejo-backups
install -d -m 0700 /home/home/.local/libexec/forgejo-backup/forgejo \
  /home/home/.local/libexec/forgejo-backup/backups/lib \
  /home/home/.local/libexec/forgejo-backup/backups/config \
  /home/home/.config/systemd/user
install -m 0700 forgejo/backup.sh /home/home/.local/libexec/forgejo-backup/forgejo/backup.sh
install -m 0600 backups/lib/common.sh /home/home/.local/libexec/forgejo-backup/backups/lib/common.sh
install -m 0600 backups/config/forgejo.sh /home/home/.local/libexec/forgejo-backup/backups/config/forgejo.sh
install -m 0600 forgejo/forgejo-backup.service forgejo/forgejo-backup.timer /home/home/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user start forgejo-backup.service
systemctl --user enable --now forgejo-backup.timer
systemctl --user list-timers forgejo-backup.timer
```

The user manager has `Linger=yes` on this host, so it runs without an interactive
login. If rebuilding the host, an administrator must enable lingering once with
`sudo loginctl enable-linger home`. The wrapper uses the shared framework's
`with_lock` under `$XDG_RUNTIME_DIR/forgejo-backup`, an isolated temporary
`BACKUPS_ROOT`, and `retain_dumps` to keep the newest 14 proven timestamp
directories. Failed backup/drill runs fail the systemd service; inspect
`journalctl --user -u forgejo-backup.service`. No Discord webhook is configured
for this user service.

## Restore

Proven archives live at `/mnt/tank/shared/forgejo-backups/forgejo/<stamp>/<stamp>.tar.gz`. The service root is mode 0700, owned by `home`; tarballs are mode 0600. `/mnt/tank/shared/Backups` is owned by uid 3000 and not writable by this user, so its permissions were not changed. The shared framework's default `/mnt/tank/shared/backups` resolves to that same directory on this case-insensitive ZFS dataset and is not the user service destination.

Each archive contains `gitea.db` at its timestamp-directory root, plus `git/repositories`, `gitea/conf/app.ini`, `gitea/jwt`, `gitea/actions_id_token` and `git/.ssh` when present. Files containing secrets and the archive are owner-only. Keep the archive private.

Stop Forgejo writes before restoring. Extract into a private temporary directory, then copy `gitea.db` to `/mnt/tank/shared/forgejo/gitea/gitea.db` and the remaining trees to their matching paths. Remove stale `gitea.db-wal` and `gitea.db-shm` while the service is stopped, restore owner uid/gid 1000, and start Forgejo. Preserve the original `app.ini`: its secret key decrypts generated push-mirror SSH keys stored in the DB.

The Python stdlib SQLite backup API takes a consistent online DB snapshot, including committed WAL data, and checks integrity. The isolated restore drill checks `PRAGMA integrity_check`, nonempty user/repository tables and `git fsck` on every restored bare repository without starting Forgejo or connecting to production. Repository enumeration must succeed, and the restored non-wiki repository count must cover the database repository count; an empty or incomplete repository tree cannot pass. Repositories are copied live, not atomically with the DB; stop writes before an upgrade backup if a single application-wide recovery point is required. This is a code/history/configuration backup: attachments, LFS objects, packages, Actions logs/artifacts and user/repository avatars are not included. Derived indexes, queues, temporary files and application logs are also omitted.

The generic suite discovers `backups/config/*.sh` relative to its installed driver. The Forgejo-only wrapper instead sources only the installed `common.sh` and `forgejo.sh`; it does not run or schedule other services. Its verified archive is moved from the temporary backup root into a timestamp directory for the shared `retain_dumps` helper. The generic all-service driver itself does not prune Forgejo's standalone tarballs.

## Break-glass

- Forgejo down: the running jott server keeps serving, but new deployments read Forgejo directly through Dokploy's Gitea provider. Restore the verified Forgejo backup first. For emergency deployment, switch only jott's Dokploy source back to the GitHub mirror; it contains the last successful push sync. Local clones retain full git history.
- Locked out: `docker exec -u git forgejo forgejo admin user change-password --username <name> --password <new>`.
- Jott deployment: provider `Forgejo git.imapps.uk` uses a separate read-only token. A main-branch push webhook targets Dokploy over LAN HTTPS, restricted by `FORGEJO__webhook__ALLOWED_HOST_LIST=dokploy.imapps.uk`; watch paths remain `server/**` and `schema/**`. The webhook URL contains a deployment secret and must not be committed.
- Runner stuck: `docker restart forgejo-runner`; wedged job containers live inside dind (`docker exec forgejo-dind docker ps`).
- To pause CI: `docker stop forgejo-runner`.
