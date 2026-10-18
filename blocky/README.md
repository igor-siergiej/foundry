# blocky

LAN-wide DNS resolver for the house: split-horizon for `imapps.uk`, MagicDNS forwarding for `ts.net`,
and StevenBlack adware+malware blocking. Every Deco DHCP client and the `foundry` host itself use it,
so it is a whole-house dependency. Client setup, verification `dig`s and the secondary-DNS trade-off
are in the repo root [`../README.md`](../README.md#blocky-dns-server); the ingress picture is
[`homelab.md` §2](../docs/homelab.md#2-ingress--dns-how-a-request-reaches-a-service).

| | |
|---|---|
| Dokploy | project `infra`, compose `blocky` (`infra-blocky-ezfowk`), path `blocky/docker-compose.yml` |
| Image | `spx01/blocky:latest` — unpinned, see `../SECURITY-AUDIT.md` #8 |
| Ports | `53/tcp` + `53/udp` published on all host interfaces. `4000` (HTTP API + `/metrics`) is **not** published; reachable only on `dokploy-network` |
| Ingress | none (no Dokploy domain, no Traefik route) |
| Networks | `infra` (stack-local bridge), `dokploy-network` (external) |
| Mounts | `./config.yml` → `/app/config.yml:ro`. No volumes, no state |
| Env | none |
| Restart | `restart: always` (not `unless-stopped`) — see gotchas |

## Config (`config.yml`)

- `customDNS.mapping.imapps.uk: 192.168.68.17` — `*.imapps.uk` resolves to the host LAN IP, so LAN and
  tailnet clients hit `dokploy-traefik` directly and **bypass Cloudflare Access**.
- `conditional.mapping.ts.net: 100.100.100.100` — forwards MagicDNS to tailscaled's stub. This is half
  of the host-DNS fix in [`homelab.md` §4a](../docs/homelab.md#4a-host-dns-resolution-on-foundry-fixed-2026-09-27).
- Upstreams `1.1.1.1`, `8.8.8.8`; bootstrap `1.1.1.1`.
- Blocking: StevenBlack unified hosts only (deliberately no gambling/porn/fakenews lists), `zeroIp`,
  refreshed every 24h, `loading.strategy: fast` so DNS serves before lists finish downloading.
- `filtering.queryTypes: [AAAA]` — AAAA is dropped; the LAN is IPv4-only.
- Prometheus metrics on `:4000/metrics`, scraped by `monitoring` (`job_name: blocky`).

## Deploy / change

Edit `config.yml` or the compose file, commit + push, then run `compose-deploy` explicitly — see
[`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change). The config is
bind-mounted, so a redeploy is what picks up changes.

Verify afterwards (from the root README):

```sh
dig @192.168.68.17 +short shoppingo.imapps.uk   # 192.168.68.17
dig @192.168.68.17 +short doubleclick.net       # 0.0.0.0
getent hosts home.tail2d4575.ts.net             # 100.79.92.93 (on foundry)
```

## Health / monitoring

- Container healthcheck: `/app/blocky healthcheck` every 30s (the image is distroless — no shell or curl).
- Gatus: `Blocky (DNS)` → `http://blocky:4000/api/blocking/status` (group Core). Gatus also has a
  `DNS Resolution` check, but it targets `1.1.1.1:53`, not blocky.
- Prometheus scrapes `blocky:4000`.

## Backups

None needed: the only state is `config.yml`, which is in git.

## Gotchas

- **The host's own primary resolver is this container** (netplan pins `192.168.68.17`, `1.1.1.1`).
  Never leave blocky down while doing anything that needs DNS to bring it back. That is why it is
  `restart: always`. See [`homelab.md` §4a](../docs/homelab.md#4a-host-dns-resolution-on-foundry-fixed-2026-09-27).
- Port 53 collides with systemd-resolved's stub listener, so the stub is disabled on the host and
  `resolvectl domain` split DNS has no effect. Route domains through `config.yml` instead.
- A false-positive block breaks that site for every device in the house. Add an `allowlists` entry
  rather than disabling blocking ([`homelab.md` §10](../docs/homelab.md#10-gotchas-checklist-for-future-agents)).
- During a restart, clients can fall through to `1.1.1.1`, get the Cloudflare-proxied answer for
  `*.imapps.uk` and see an Access prompt for ~300s.
- Long-lease DHCP devices may still be on the old resolvers; check `docker logs blocky` for
  `192.168.68.x` clients before trusting LAN-wide numbers.
