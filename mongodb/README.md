# MongoDB Compose Setup

Docker Compose setup for MongoDB 7.0, serving shoppingo and jewellery-catalogue (staging + production).

## Quick Start

1. Copy `.env.example` to `.env` and update credentials:
   ```bash
   cp .env.example .env
   # Edit .env with your passwords
   ```

2. Start MongoDB:
   ```bash
   docker compose up -d
   ```

3. Verify it's running:
   ```bash
   docker compose ps
   docker exec mongodb mongosh -u admin -p <MONGO_ROOT_PASSWORD> --authenticationDatabase admin --eval "show dbs"
   ```

## Creating Application Users

Create users after MongoDB starts:

```bash
docker exec mongodb mongosh -u admin -p <MONGO_ROOT_PASSWORD> --authenticationDatabase admin <<'EOF'
db = db.getSiblingDB('shoppingo_production');
db.createUser({ user: 'shoppingo_production_user', pwd: '<APP_PASSWORD>', roles: ['readWrite'] });

db = db.getSiblingDB('shoppingo_staging');
db.createUser({ user: 'shoppingo_staging_user', pwd: '<APP_PASSWORD>', roles: ['readWrite'] });

db = db.getSiblingDB('jewellery_production');
db.createUser({ user: 'jewellery_production_user', pwd: '<APP_PASSWORD>', roles: ['readWrite'] });

db = db.getSiblingDB('jewellery_staging');
db.createUser({ user: 'jewellery_staging_user', pwd: '<APP_PASSWORD>', roles: ['readWrite'] });
EOF
```

## Testing Application Connection

```bash
docker exec mongodb mongosh "mongodb://shoppingo_production_user:<APP_PASSWORD>@localhost:27017/shoppingo_production?authSource=shoppingo_production"
```

## Remote Access

MongoDB publishes no host port and has no Traefik route — it is reachable only
from containers on `dokploy-network` (apps use `mongodb:27017`). For a shell,
run `docker exec -it mongodb mongosh ...` on the host.

For a GUI client (Compass etc.) on another machine, start a throwaway forwarder
bound to the host's loopback, then SSH-tunnel to it:

```bash
# on foundry
docker run --rm -d --name mongo-tunnel --network dokploy-network \
  -p 127.0.0.1:27018:27017 alpine/socat TCP-LISTEN:27017,fork TCP:mongodb:27017
# on your machine
ssh -L 27017:127.0.0.1:27018 home@foundry
# connect to mongodb://...@localhost:27017/?authSource=admin, then:
docker stop mongo-tunnel   # on foundry, when done
```

## NFS Persistence (TrueNAS)

Data is currently stored locally. To switch to NFS persistence:

1. Create NFS export on TrueNAS at `/mnt/tank/shared/mongodb`
2. Uncomment the `driver_opts` section in `docker-compose.yml`
3. Stop MongoDB and remove local volume:
   ```bash
   docker compose down -v
   ```
4. Restart with NFS:
   ```bash
   docker compose up -d
   ```

## Database Schema

Applications use separate databases:
- `shoppingo_production` / `shoppingo_staging`
- `jewellery_production` / `jewellery_staging`

Each has a corresponding user with readWrite role on that database.
