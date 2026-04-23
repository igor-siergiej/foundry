# Uptime-Kuma Setup

Automatically generate health monitors for all homelab services in uptime-kuma.

## Prerequisites

- Bun runtime installed (https://bun.sh)
- Uptime-kuma running and accessible at `http://localhost:3001` (or configure `UPTIME_KUMA_URL`)
- API access to uptime-kuma (API key required)

## Getting API Key

1. Log in to uptime-kuma web UI
2. Go to Settings → API Keys
3. Create a new API key
4. Copy the key value

## Setup Steps

### 1. Create .env file

```bash
cd foundry/scripts
cp .env.example .env
```

Edit `.env`:
```
UPTIME_KUMA_URL=http://uptime-kuma:3001
UPTIME_KUMA_API_KEY=your-api-key-here
```

### 2. Install dependencies with Bun

```bash
cd foundry/scripts
bun install
```

### 3. Run setup script

```bash
bun setup
```

Expected output:
```
Uptime-Kuma Setup

✓ Connected to uptime-kuma

📋 Loading configuration...

🔍 Setting up monitors...
  + Created: Blocky (DNS)
  + Created: Immich (Photos)
  + Created: MongoDB
  + Created: MinIO (Storage)
  + Created: Jellyfin (Media)
  + Created: Navidrome (Music)
  + Created: AudiobookShelf
  + Created: Home Assistant
  + Created: Prometheus
  + Created: Grafana

📊 Setting up dashboard...
  + Created dashboard: Homelab Status
  ✓ Added 10 monitors to dashboard

✓ Setup complete!
View dashboard at: http://uptime-kuma:3001/status/homelab-status
```

### 4. Verify in Web UI

- Navigate to uptime-kuma web UI
- Click "Status Pages" in left sidebar
- Select "Homelab Status"
- Verify all 10 services are listed

## Adding New Services

1. Edit `foundry/uptime-kuma-config.yml`
2. Add new monitor entry (copy an existing one, adjust details)
3. Run `bun setup` again
4. Script will create new monitor and add it to dashboard

## Updating Health Check URLs

1. Edit `foundry/uptime-kuma-config.yml`
2. Update the `url` field for the service
3. Run `bun setup` again
4. Monitor will be updated automatically

## Troubleshooting

**"Failed to connect to uptime-kuma"**
- Check `UPTIME_KUMA_URL` in `.env`
- Verify uptime-kuma container is running: `docker ps | grep uptime-kuma`
- Test connectivity: `curl http://localhost:3001`

**"API key invalid"**
- Verify `UPTIME_KUMA_API_KEY` in `.env`
- Re-generate key in uptime-kuma Settings → API Keys

**"Monitor creation failed"**
- Check health check URL is accessible from uptime-kuma container
- For internal services, use container names (e.g., `http://jellyfin:8096`) not IPs
- Monitor logs: `docker logs uptime-kuma`

## Running on Dokploy Deploy

To auto-run this setup after Dokploy deployment, add to monitoring service docker-compose:

```yaml
services:
  uptime-kuma-init:
    image: oven/bun:latest
    working_dir: /app/scripts
    entrypoint: ["bun", "setup"]
    environment:
      UPTIME_KUMA_URL: http://uptime-kuma:3001
      UPTIME_KUMA_API_KEY: ${UPTIME_KUMA_API_KEY}
    depends_on:
      - uptime-kuma
    volumes:
      - ../uptime-kuma-config.yml:/app/uptime-kuma-config.yml:ro
      - ../scripts:/app/scripts:ro
    networks:
      - monitoring
    profiles:
      - init
```

Then run: `docker-compose --profile init up`

(This is optional — manual `bun setup` is simpler for now.)
