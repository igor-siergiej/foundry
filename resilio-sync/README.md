# Resilio Sync

Peer-to-peer sync of the notes directory (`/mnt/tank/shared/notes`) across Igor's devices. Tailnet-only.

- **Dokploy:** project `nas`, compose `resilio-sync` (appName `compose-override-solid-state-driver-jkl5vn`),
  source `foundry` repo `resilio-sync/docker-compose.yml`, branch `main`.
- **Image:** `resilio/sync:latest` (official image) — unpinned ([`../SECURITY-AUDIT.md`](../SECURITY-AUDIT.md) #8).
- Runs as `user: 1000:1000` (`home`) so synced files stay editable by agents on the host. `TZ=Europe/London`.

## Ingress

No Traefik route, no `*.imapps.uk` hostname, no Cloudflare involvement. Ports are published on the
**tailnet IP only**:

| Host bind | Purpose |
|---|---|
| `100.79.92.93:8888` | web UI (login required) |
| `100.79.92.93:55555/tcp` | sync |
| `100.79.92.93:55555/udp` | sync |

## Networks

`dokploy-network` (external), which is how Gatus reaches the UI.

## Storage

| Volume | Mount | Backing |
|---|---|---|
| `resilio-config2` | `/mnt/sync` (`sync.conf`, Resilio state) | Docker named volume, host disk |
| `notes` | `/mnt/sync/notes` (rw) | bind `/mnt/tank/shared/notes` (ZFS) |

The notes folder pairing is stored in `resilio-config2` and was added through the web UI; it is not in the
compose. Losing that volume means re-adding the folder (and re-linking peers) by hand.

## Environment

No Dokploy env vars or secrets in the compose.

## Deploy / change

Commit + push, then explicit `compose-deploy`
([homelab.md §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change)).

## Health and backups

- Gatus: `Resilio Sync` → `http://resilio-sync:8888/gui/`, expects **401** (UI requires login, so 401 = up).
- Backup: **none** for `resilio-config2`. The notes themselves are on the ZFS mirror and replicated to every
  synced device ([homelab.md §9](../docs/homelab.md#9-backups--restore-drill)).

## Gotchas

- The tailnet IP `100.79.92.93` is hardcoded in the port binds. If the host's tailnet IP changes (it did in
  the 2026-08-20 reinstall, see [homelab.md §1](../docs/homelab.md#1-physical--network-topology)), the
  container fails to start until the compose is updated.
- The deployed stack was once hand-edited on the host to run the official image as root, so notes ended up
  root-owned (fixed in `fbdf161`). Keep `user: '1000:1000'` and change the stack through git, not on the host.
- Tailnet ACL is allow-all, so every tailnet node (including `gtnh`) can reach the UI and sync ports
  ([`../SECURITY-AUDIT.md`](../SECURITY-AUDIT.md) #1).
