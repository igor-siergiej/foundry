# tailscale

Host tailnet node for `foundry` (`100.79.92.93`, MagicDNS `foundry`), advertising the LAN
`192.168.68.0/24` as a subnet route so tailnet devices reach LAN services remotely. The GTNH server has
its own separate sidecar node (see [`../gtnh/README.md`](../gtnh/README.md)). Inventory row:
[`homelab.md` §5 `infra`](../docs/homelab.md#infra).

| | |
|---|---|
| Dokploy | project `infra`, compose `tailscale` (`infra-tailscale-fx7r6q`), path `tailscale/docker-compose.yml` |
| Image | `tailscale/tailscale:v1.104.2`, digest-pinned (`@sha256:b11583…`, go1.27.3, 2026-10-26); Dependabot bumps the digest |
| Networking | `network_mode: host`, `TS_USERSPACE=false` (kernel `tailscale0` in the host netns) |
| Ingress | none (no Dokploy domain, no Traefik) |
| Caps / devices | `NET_ADMIN`, `NET_RAW`, `/dev/net/tun` |
| Volumes | `tailscale-state` → `/var/lib/tailscale` (named volume on the host disk, not backed up) |
| Env | `TS_AUTHKEY` (Dokploy env); `TS_ROUTES=192.168.68.0/24`, `TS_STATE_DIR` set in compose |

## Deploy / change

Commit + push, then `compose-deploy` — [`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change).
The auth key is only used on first login; the node identity lives in `tailscale-state`. Tailnet-side
changes (ACL, route approval, DNS) go through the tailscale MCP ([`homelab.md` §4](../docs/homelab.md#4-mcp-control-planes-how-an-agent-operates-this-homelab)).

## Health / monitoring

No Gatus check and no container healthcheck for this node. Indirect coverage: Gatus's
`GTNH (Minecraft)` check resolves `*.ts.net` through blocky → `100.100.100.100`, which needs this
container's tailscaled. Check `docker exec tailscale tailscale status`.

## Backups

None. Losing `tailscale-state` means re-authenticating with a new `TS_AUTHKEY` (new node key).

## Gotchas

- tailscaled runs in a container, so the `/etc/resolv.conf` it writes stays in the container's mount
  namespace; the host never gets MagicDNS from it. Host DNS goes via blocky's `ts.net` forward and
  netplan instead — [`homelab.md` §4a](../docs/homelab.md#4a-host-dns-resolution-on-foundry-fixed-2026-09-27).
  `tailscale set --accept-dns=true` does not fix this.
- The tailnet ACL is allow-all and this node advertises the whole LAN, so every tailnet peer
  (including `gtnh`) reaches every LAN host — `../SECURITY-AUDIT.md` #1 (HIGH, open).
- Tailnet clients that use blocky bypass Cloudflare Access just like LAN clients.
