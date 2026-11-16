# Forgejo — self-hosted git + Actions runner

## What / where

| Service | Image | Port | Notes |
|---|---|---|---|
| `forgejo` | `data.forgejo.org/forgejo/forgejo:17.0.1@sha256:fcd19ff4…` | 3000 (internal) | `git.imapps.uk`, Tailscale/LAN-only: no public DNS record, no Access. SSH disabled, registration disabled, SQLite. |
| `dind` | `data.forgejo.org/oci/docker:29-dind@sha256:7bf70dcb…` | 2375 (private `forgejo` network only) | Privileged Docker daemon for CI jobs. Plain TCP is fine: never published, not on `dokploy-network`, and job containers get no docker access (`docker_host: "-"`). |
| `runner` | `data.forgejo.org/forgejo/runner:13.2.1@sha256:568cea8c…` | — | Label `ubuntu-latest` (`ghcr.io/catthehacker/ubuntu:act-22.04`), capacity 2, `mem_limit: 2g` (jobs run in dind, limited to 8g/8 cpus each). Config is an inline compose `configs:` entry mounted at `/config.yml`. |

- Data: `forgejo-data` → `/data`, local bind to `/mnt/tank/shared/forgejo` (ZFS). `dind-data` and `runner-data` are named volumes.
- The `git.imapps.uk` → `forgejo:3000` Dokploy domain is created in Dokploy, not in this file. Dokploy attaches `dokploy-network` for it.
- Gatus: `Forgejo` → `https://git.imapps.uk/api/healthz`. Backup: `backups/config/forgejo.sh` (nightly, 14 kept).

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
Forgejo migrates the DB on start and cannot be downgraded: take a manual backup first (`backups/bin/backup.sh`), and roll back by restoring it plus the previous pin.
v17.0 is a non-LTS release, EOL 2027-01-28; plan the move to the v19 LTS before then.

## Restore

Latest dump: `/mnt/tank/shared/backups/forgejo/<stamp>.tar.gz` (contains `gitea.db`, `git/repositories`, `gitea/conf/app.ini`, `gitea/jwt`). Stop the stack, extract into `/mnt/tank/shared/forgejo` (db → `gitea/gitea.db`, others at the same relative paths, owner uid 1000), start. The weekly restore drill runs `PRAGMA integrity_check` and `git fsck` on every repo.

## Break-glass

- Forgejo down: jott deploys from the GitHub mirror, so production deploys are unaffected. Local clones still have full history.
- Locked out: `docker exec -u git forgejo forgejo admin user change-password --username <name> --password <new>`.
- Runner stuck: `docker restart forgejo-runner`; wedged job containers live inside dind (`docker exec forgejo-dind docker ps`).
- To pause CI: `docker stop forgejo-runner`.
