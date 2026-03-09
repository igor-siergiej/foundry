# Foundry - Infrastructure Services

Docker Compose stack for Dokploy infrastructure services deployment.

## Services

### Blocky (DNS Server)

Local split-horizon DNS server that provides:
- **Local DNS resolution** for homelab services via `*.example.com` mappings
- **External DNS forwarding** to Cloudflare and Google DNS
- **Web UI** on port 4000 for monitoring and management
- **TCP/UDP** DNS on port 53

#### Configuration

Edit `infrastructure/blocky/config.yml` and replace `GATEWAY_IP` with your local gateway IP:

```yaml
customDNS:
  mapping:
    example.com: 192.168.69.1        # Replace with your gateway IP
    "*.example.com": 192.168.69.1    # All subdomains route to gateway
```

This allows LAN clients to access internal services (Dokploy, Immich, etc.) directly without routing through the Cloudflare tunnel.

#### Deployment with Dokploy

1. Connect this repository to Dokploy with Git Sync
2. Dokploy will pull `docker-compose.yml` and deploy the Blocky service
3. Update `GATEWAY_IP` placeholder before first deployment
4. Access web UI at `http://<server-ip>:4000`

## Directory Structure

```
foundry/
├── docker-compose.yml              # Main compose file
└── infrastructure/
    └── blocky/
        └── config.yml              # Blocky configuration
```

## Notes

- Blocky restarts automatically unless explicitly stopped (`unless-stopped` policy)
- Config file is mounted as read-only volume from repository
- DNS blocking lists are optional and can be disabled by removing the `blocking` section
- Prometheus metrics available at `/metrics` for monitoring integration
