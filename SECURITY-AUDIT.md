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

### 10. Docker socket mounted into promtail — LOW
`:ro` on a socket bind does not restrict the API — promtail can create privileged containers. Put a
read-only socket proxy (e.g. `tecnativa/docker-socket-proxy` with only `CONTAINERS=1`) in front.

### 11. `minio-gallery` routed on plain HTTP only — LOW
The Traefik router for `minio-gallery.imapps.uk` uses the `web` entrypoint only, so on the LAN the
Filestash admin login goes over plaintext HTTP. Remote traffic is TLS via Cloudflare. Fix: move the
router to `websecure` with the letsencrypt certresolver.

### 12. `sentinel-api` runs with outbound TLS verification disabled — LOW
`sentinel/packages/api/src/index.ts` sets `NODE_TLS_REJECT_UNAUTHORIZED=0` whenever
`NODE_ENV !== "production"`, and neither the root `Dockerfile.api` nor the Dokploy env sets
`NODE_ENV` (live `printenv NODE_ENV` in `sentinel-api-vnfxap` is empty, checked 2026-10-17). Every
outbound HTTPS call from the API — including Home Assistant calls carrying the long-lived
`HA_TOKEN` — accepts any certificate. Severity rises to MEDIUM if `HA_URL` is an `https://` LAN
hostname rather than the internal container address (value redacted in Dokploy, not determined).
**Fix:** `ENV NODE_ENV=production` in `sentinel/Dockerfile.api`, or set it in the Dokploy env.

## Closed 2026-10-18

### 2. NFS export was read-write to the entire tailnet CGNAT range — was HIGH
`/etc/exports` exported `/mnt/tank/shared 100.64.0.0/10(rw,sync,no_subtree_check,crossmnt)`, so
any tailnet node could mount and rewrite vaultwarden, mongodb, immich, grafana and Home Assistant
data. No established `:2049` connections existed, so the line was removed rather than narrowed
(commented out in `/etc/exports`, backup at `/etc/exports.bak-2026-10-18`; `sudo exportfs -ra`).
`showmount -e localhost` now lists only the ZFS `sharenfs` exports: `/mnt/tank/k8s-nfs *` (#7 in
jott) and `shared/{minio,jellyfin,immich}` to `192.168.69.250`. `nfs-server`/`rpcbind` stay up for
those, so they were not firewalled.

### 4. SSH password authentication on the LAN — was MEDIUM
Before the change `sshd -T` showed `passwordauthentication no` (set by `50-cloud-init.conf`) but
`permitrootlogin prohibit-password`. Added `/etc/ssh/sshd_config.d/10-hardening.conf` with
`PasswordAuthentication no` and `PermitRootLogin no` (sorts before `50-cloud-init.conf`, so it
wins), `sshd -t` clean, `systemctl reload ssh`. `sshd -T` now shows `permitrootlogin no` and
`passwordauthentication no`; a password-only login from `framework` is refused with
`Permission denied (publickey)`.

### 3. Dokploy UI published on `0.0.0.0:3000` over plain HTTP — was HIGH
`docker service update --publish-rm published=3000,target=3000,mode=host dokploy`; service converged
(`Endpoint.Spec.Ports: null`). On re-check the host listener was an orphaned `bunx vite --port 3000
--host` dev process (PID 1800419, ~2 days old, `--host` ⇒ `0.0.0.0`), not the swarm publish — killed
the process. `ss -tln` no longer shows `:3000`; `https://dokploy.imapps.uk` returns 200 on the
login page and 401 on the tRPC bootstrap (auth required); the dokploy MCP answered the read-tools
used to scope and verify this change. Recheck after every Dokploy upgrade (audit finding reopened
on 2026-10-18 because of the v0.30.8 upgrade).

### 9. Traefik API in insecure mode — was LOW
`settings.updateTraefikConfig` (dokploy-mcp) wrote the live config with `api.insecure: false`,
followed by `settings.reloadTraefik`. `settings.readTraefikConfig` confirms the live file now has
`api: { insecure: false }`. From `shoppingo-api-zlusv1.1.9k8qob2jkm4t8z2f5r3cen6z5` (a container
on `dokploy-network`) a raw TCP `GET /api/rawdata` to `dokploy-traefik:8080` now reports
`Connection refused`; an HTTP 301 from `:80 → :443` for `gatus.imapps.uk` still resolves correctly
(routing intact). Dokploy UI does not enable the Traefik dashboard, so the change is safe. Recheck
after every Dokploy upgrade (same gotcha as #3; both flipped by the v0.30.8 re-deploy).

## Closed 2026-10-14

### Filestash (`minio-gallery`) admin console had no password — was HIGH
`/healthz` reported `admin.auth[size=0]` and `/admin/api/config` answered unauthenticated from the
LAN. Admin password set 2026-10-14; `/admin/api/config` now returns 403.

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
