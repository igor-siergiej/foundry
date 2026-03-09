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

Edit `blocky/config.yml` and replace `GATEWAY_IP` with your local gateway IP:

```yaml
customDNS:
  mapping:
    example.com: 192.168.69.1        # Replace with your gateway IP
    "*.example.com": 192.168.69.1    # All subdomains route to gateway
```

This allows LAN clients to access internal services (Dokploy, Immich, etc.) directly without routing through the Cloudflare tunnel.

#### Deployment with Dokploy

1. Connect this repository to Dokploy with Git Sync
2. Set compose file path to `blocky/docker-compose.yml`
3. Dokploy will pull and deploy the Blocky service
4. Update `GATEWAY_IP` placeholder in `blocky/config.yml` before first deployment
5. Access web UI at `http://<server-ip>:4000`

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

- Blocky restarts automatically unless explicitly stopped (`unless-stopped` policy)
- Config file is mounted as read-only volume from repository
- DNS blocking lists are optional and can be disabled by removing the `blocking` section
- Prometheus metrics available at `/metrics` for monitoring integration
