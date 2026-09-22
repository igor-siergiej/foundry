# Foundry - Infrastructure Services

Docker Compose stack for Dokploy infrastructure services deployment.

> Full infra docs (topology, deploy flow, service inventory, security findings) live in [`docs/`](./docs/README.md).

## Services

### Blocky (DNS Server)

LAN-wide DNS resolver doing split-horizon plus ad/malware blocking:
- **Split-horizon DNS** — `imapps.uk` and all subdomains resolve to `192.168.68.17`, so LAN clients reach `dokploy-traefik` directly instead of going out through the Cloudflare tunnel
- **Ad/malware blocking** — StevenBlack unified hosts (adware + malware only), refreshed daily
- **External DNS forwarding** to Cloudflare (`1.1.1.1`) and Google (`8.8.8.8`)
- **TCP/UDP** DNS on port 53, published on the host
- **Prometheus metrics** at `:4000/metrics`, internal to `dokploy-network` (scraped by the monitoring stack; not published to the host)

#### Client configuration (required — this is what makes it work)

Blocky only serves clients that are told to ask it. Set this on the **TP-Link Deco**
(Deco app → Advanced → DHCP Server):

| Field | Value |
|---|---|
| Primary DNS | `192.168.68.17` |
| Secondary DNS | `1.1.1.1` |

Devices pick this up on their next DHCP lease renewal; a WiFi reconnect forces it.

> **Secondary-DNS trade-off:** `1.1.1.1` keeps the internet working if blocky is
> down, but while blocky restarts a client may fall through to it, get the
> Cloudflare-proxied answer for `*.imapps.uk`, and see a Cloudflare Access prompt
> until that record's ~300s TTL expires. Accepted deliberately over a
> no-internet-if-blocky-dies setup.

#### Deployment with Dokploy

1. Repository is connected to Dokploy via Git Sync (`infra` project, `blocky` stack)
2. Compose file path is `blocky/docker-compose.yml`
3. **Commit and push first** — Dokploy deploys from GitHub HEAD, not local files
4. Trigger `compose-deploy` explicitly; the autoDeploy webhook is unreliable

#### Verifying

```bash
dig @192.168.68.17 +short shoppingo.imapps.uk   # -> 192.168.68.17 (split horizon)
dig @192.168.68.17 +short doubleclick.net       # -> 0.0.0.0       (blocked)
dig @192.168.68.17 +short github.com            # -> real address  (not over-blocking)
```

To confirm real LAN clients are actually using it, look for `192.168.68.x`
addresses in `docker logs blocky` — only `100.x` tailnet clients appearing means
the Deco DHCP setting hasn't taken effect.

## Directory Structure

```
foundry/
├── blocky/
│   ├── docker-compose.yml          # Blocky service definition
│   └── config.yml                  # Blocky configuration
├── README.md
└── .gitignore
```

## Notes

- Blocky uses `restart: always` — it is the whole LAN's resolver, so it must return after a daemon restart, not just a container crash
- Healthcheck uses blocky's built-in `blocky healthcheck` subcommand (the image is distroless — no shell, no curl)
- Config file is mounted read-only from the repository
- Blocklists are fetched with `loading.strategy: fast`, so DNS is served immediately on start even if the list download is slow
- `filtering.queryTypes: [AAAA]` drops AAAA lookups; the LAN is IPv4-only
