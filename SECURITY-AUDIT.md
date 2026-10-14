# Security audit — foundry homelab

Open and recently closed findings for the Dokploy host and its stacks. Referenced from
[`docs/homelab.md`](./docs/homelab.md). Last full pass: 2026-10-10, against the live host
(`docker ps`, `ss -tlnp`, `/etc/exports`, Traefik config, tailnet ACL), not just this repo.

Context that shapes severity: Cloudflare Access only gates *remote* traffic. Since 2026-09-22 every
WiFi device (guests, IoT) resolves `*.imapps.uk` to the LAN IP via blocky and bypasses Access, and
any port bound to `0.0.0.0` on this host is reachable from the whole LAN.

## Open

### 1. Tailnet ACL is allow-all, including the GTNH node — HIGH
Policy is a single grant `{"src": ["*"], "dst": ["*"], "ip": ["*"]}`. `gtnh` (`tag:mc-server`) runs a
modded Minecraft server (hundreds of third-party jars) and is a full tailnet peer, so a compromise
there reaches foundry on every port (SSH, Paperclip `:8443/:8444`, Resilio UI, NFS) and the whole
`192.168.68.0/24` subnet foundry advertises.
**Fix:** grant `autogroup:member → *`, `autogroup:shared → tag:mc-server:tcp:25565`, nothing from
tagged nodes. Prepared policy needs applying via `tailscale:manage_acl` or the admin console.

### 2. NFS export is read-write to the entire tailnet CGNAT range — HIGH
`/etc/exports`: `/mnt/tank/shared 100.64.0.0/10(rw,sync,no_subtree_check,crossmnt)`. That share
holds vaultwarden, mongodb, immich, grafana and Home Assistant data. NFS `AUTH_SYS` trusts the
client's claimed UID, so `root_squash` only protects root-owned files. Combined with #1, any tailnet
node can mount and rewrite it.
**Fix (needs sudo):** restrict to the specific client IPs that actually mount it (e.g.
`100.91.45.105` for `framework`) and add `all_squash` or a dedicated `anonuid` if the clients only
need one identity; `sudo exportfs -ra`. Also `rpcbind`/`mountd` (`:111` and random high ports)
listen on `0.0.0.0` — if nothing on the LAN mounts it, firewall them to `tailscale0`.

### 3. Dokploy UI published on `0.0.0.0:3000` over plain HTTP — HIGH
The `dokploy` swarm service publishes `3000` in host mode. Any LAN device reaches the admin panel
(root-equivalent on this host via Docker) without TLS, so the login is sniffable on WiFi. Traefik
already serves it at `dokploy.imapps.uk` via `http://dokploy:3000` over `dokploy-network`, and the
dokploy MCP uses the domain, so nothing depends on the raw port.
**Fix:** `docker service update --publish-rm published=3000,target=3000,mode=host dokploy`.
Dokploy upgrades may re-add it — recheck after each upgrade.

### 4. SSH password authentication enabled on the LAN — MEDIUM
`sshd` listens on `0.0.0.0:22`; `PasswordAuthentication` is unset (default `yes`).
**Fix (needs sudo):** drop-in `/etc/ssh/sshd_config.d/10-hardening.conf` with
`PasswordAuthentication no` and `PermitRootLogin no`, then `sudo systemctl reload ssh`. Confirm a
key login works in a second session first.

### 5. Host-disk volumes with no backup — MEDIUM
Only `immich-pgdata` (557 MB) lives on the host disk; the audit previously also listed `minio-data`
but on re-check 2026-10-10 it is already a bind mount to `/mnt/tank/shared/minio` (Dokploy switched
it during the 2026-10 host-port hardening — `docker volume inspect minio-data` shows
`Options.device: /mnt/tank/shared/minio`, `Options.type: none`). `immich-upload` was also already
on the tank. Host disk loss is still data loss for the postgres data. Move to a bind mount under
`/mnt/tank/shared/immich-pgdata` or add a backup job.

### 6. MinIO is on an unpatched, frozen image — MEDIUM
Running `RELEASE.2025-09-07T16-13-09Z`. MinIO stopped publishing community Docker images in late
2025, so `minio/minio:latest` will never pick up later fixes (e.g. the October 2025 service-account
privilege-escalation fix). The console is on `minio-console.imapps.uk`, reachable on-LAN.
**Fix:** build from source / switch to a maintained community image, or migrate to an S3-compatible
alternative; at minimum drop the `minio-console` Traefik route when not in use.

### 7. Home Assistant is ~2 years old — MEDIUM
Pinned `2024.12.3`. Upgrade in steps and check breaking changes; only the `sun` and `go2rtc`
integrations remain, so risk is low.

### 8. Unpinned `:latest` images — LOW
blocky, minio, navidrome, audiobookshelf, filestash, gatus, resilio-sync, tailscale (×2),
cloudflared. Every redeploy pulls whatever upstream published, with no review. Pin to versions and
let Renovate/Dependabot bump them.

### 9. Traefik API in insecure mode — LOW
`/etc/dokploy/traefik/traefik.yml` has `api.insecure: true`. Not host-published, but every container
on `dokploy-network` (including internet-facing app containers) can read the full routing config on
`dokploy-traefik:8080`. Dokploy owns this file; set it to `false` if the Dokploy UI does not need the
dashboard.

### 10. Docker socket mounted into promtail — LOW
`:ro` on a socket bind does not restrict the API — promtail can create privileged containers. Put a
read-only socket proxy (e.g. `tecnativa/docker-socket-proxy` with only `CONTAINERS=1`) in front.

### 11. Filestash (`minio-gallery`) admin console has no password — HIGH
Found 2026-10-14. `/healthz` reports `admin.auth[size=0]`; `http://minio-gallery.imapps.uk/admin/`
redirects to `/admin/setup` and `/admin/api/config` answers unauthenticated. Remote traffic is gated
by the wildcard Access app, but any LAN/WiFi device can claim the admin account and read or rewrite
the configured connections (7, likely including MinIO credentials). The router is also on the `web`
(HTTP) entrypoint only. Fix: set the admin password via `/admin/setup` (or the `ADMIN_PASSWORD`
env), then move the router to `websecure`.

## Closed 2026-10-10

- **Vaultwarden open registration** (`d777ac7`). Live container had `SIGNUPS_ALLOWED=true` although
  `docs/README.md` claimed `false`; anyone on the LAN could register. Set to `false` in compose.
- **Home Assistant ran `privileged` + `NET_ADMIN`/`NET_RAW`** (`d777ac7`). Bridge network, no host
  devices, so no functional benefit. Removed.
- **Dev stack (`utils/docker`) published hardcoded creds on `0.0.0.0`**. `dev-navidrome` was live on
  LAN `:4533`; the compose file also bound `dev-mongodb` (`devuser/devpassword`) and `dev-minio`
  (`minioadmin`) on all interfaces. All bound to `127.0.0.1` in the utils repo.
- **Docker socket mounted into promtail** (`2da981f`). `tecnativa/docker-socket-proxy` with
  `CONTAINERS=1` + `NETWORKS=1` now fronts promtail's `docker_sd_configs`. Promtail reads log files
  from a read bind on `/var/lib/docker/containers/*` directly; the proxy only restricts the API
  surface (no `containers/create`, `exec`, `images/build`, etc). `NETWORKS=1` is the minimum needed
  because promtail's `docker_sd_configs` calls `/v1.46/networks` for label enrichment on every
  refresh, even if no `__meta_docker_network_*` label is used.
