# monitoring

Logs, metrics, dashboards/alerts and uptime checks for the whole homelab. Diagram:
[`monitoring.excalidraw`](./monitoring.excalidraw) (open in excalidraw.com or the VS Code Excalidraw
extension). Inventory row: [`homelab.md` §5 `infra`](../docs/homelab.md#infra).

Dokploy: project `infra`, compose `monitoring` (`infra-monitoring-xbyv0n`), path
`monitoring/docker-compose.yml`, deployed with a custom command:
`compose -p infra-monitoring-xbyv0n --env-file monitoring/.env -f monitoring/docker-compose.yml up -d --remove-orphans --force-recreate`.

## Services

| Service | Image | Role | Networks | Storage |
|---|---|---|---|---|
| docker-socket-proxy | `tecnativa/docker-socket-proxy:latest` | Docker API for promtail, limited to `CONTAINERS=1`, `NETWORKS=1` | monitoring | `docker.sock:ro` |
| loki | `grafana/loki:3.3.2` | log store, 30d retention (`config/loki/loki.yml`) | monitoring | `loki-data` → `/mnt/tank/shared/loki` |
| promtail | `grafana/promtail:3.3.2` | ships every running container's logs to loki; labels `container`, `compose_project`, `compose_service`, `stream`, `level` (JSON logs) | monitoring | `/var/lib/docker/containers:ro`, `promtail-positions` (host disk) |
| prometheus | `prom/prometheus:v3.2.1` | metrics, 30d TSDB, `--web.enable-lifecycle` | monitoring, dokploy-network | `prometheus-data` → `/mnt/tank/shared/prometheus` |
| cadvisor | `gcr.io/cadvisor/cadvisor:v0.55.1` | per-container metrics (`privileged`, `/dev/kmsg`) | monitoring | host `/`, `/sys`, `/var/lib/docker` read-only |
| node-exporter | `prom/node-exporter:v1.9.1` | host metrics (`pid: host`) | monitoring | host `/` → `/host:ro,rslave` |
| grafana | `grafana/grafana:11.5.2` | dashboards + alerting; provisioned datasources Prometheus (default) and Loki | monitoring, dokploy-network | `grafana-data` → `/mnt/tank/shared/grafana` |
| gatus | `twinproduction/gatus:latest` | uptime checks + Discord alerts, SQLite history | monitoring, dokploy-network | `./config/gatus` dir mount; `gatus-data` → `/mnt/tank/shared/gatus` |

Unpinned: docker-socket-proxy, gatus (`../SECURITY-AUDIT.md` #8 lists gatus).

## Ingress

No host ports. Traefik labels in the compose file (and matching Dokploy domains) route
`grafana.imapps.uk` → `grafana:3000` and `gatus.imapps.uk` → `gatus:8080`, HTTPS/letsencrypt, with
HTTP → HTTPS redirect. Cloudflare Access: grafana is behind the wildcard require-email app, gatus has
an explicit Bypass ([`homelab.md` §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny));
on LAN/tailnet, Grafana's own login is the only gate and Gatus is open.

## Config

- `config/prometheus/prometheus.yml` — scrape jobs: prometheus, cadvisor, node-exporter, loki, blocky
  (`blocky:4000`), shoppingo-api (`shoppingo-api-zlusv1:4001/api/metrics`), kivo (`kivo-api-1pae1e:3008`).
  The app targets use Dokploy's suffixed swarm service names; update them if the suffix changes.
- `config/prometheus/alerts.yml` — `TargetDown`, `HostDiskSpaceLow`, `HostMemoryHigh`,
  `ContainerOOMKilled`. `prometheus.yml` has no `alerting:`/Alertmanager block, so these only show
  in the Prometheus UI; they do not notify.
- `config/grafana/provisioning/alerting/` — Grafana-managed alerts (swap, memory, CPU/load, root disk,
  ZFS pool `tank` not online, container restart loop, Traefik ACME renewal failing), contact point via
  `DISCORD_WEBHOOK_URL`.
- `config/grafana/dashboards/` — host metrics, container resources, tank storage, shoppingo
  web/api, jewellery-catalogue web/api, kivo.
- `config/gatus/config.yaml` — 32 endpoints. Container-DNS checks where Gatus shares a network with
  the target; public `https://<app>.imapps.uk` for Dokploy apps and vaultwarden; sentinel-api via its
  swarm name. Alerts: Discord, 3 failures to fire, 2 successes to resolve.

## Env (Dokploy, names from `.env.example`)

`GF_ADMIN_USER`, `GF_ADMIN_PASSWORD`, `DISCORD_WEBHOOK_URL` (shared by grafana and gatus). Values live
only in Dokploy's env store.

## Deploy / change

Commit + push, then `compose-deploy` ([`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change)).
Every deploy recreates all eight containers because of `--force-recreate` in the Dokploy command;
without it, unchanged services keep bind mounts to the deleted pre-clone directory and run on stale
config ([`homelab.md` §10](../docs/homelab.md#10-gotchas-checklist-for-future-agents)). Gatus also
hot-reloads `config.yaml` because the directory, not the file, is mounted. After adding checks, run
`homelab-status`; it flags a deployed-vs-live check count mismatch.

## Health / monitoring

Gatus checks Prometheus (`/-/healthy`), Grafana (`/api/health`) and Loki (`/ready`). Nothing watches
Gatus itself except sentinel, which reads Gatus JSON via `/api/gatus/statuses`. The
`Cloudflared Tunnel (remote path)` check hits `https://tandra.uk/api/health` through the tunnel
(resolved via 1.1.1.1), since `gatus.imapps.uk` has no public DNS record. No container healthchecks in the
compose file.

## Backups

Not backed up ([`homelab.md` §9](../docs/homelab.md#9-backups--restore-drill)). Config is in git;
loki/prometheus/grafana/gatus data sit on the ZFS mirror. Grafana users/API keys and Gatus history
would be lost with the share.

## Gotchas

- `bin/sync-config.sh` (copy config to `/etc/foundry/monitoring`) is not wired up: the Dokploy command
  above does not call it and the compose file mounts `./config/...` directly. It was superseded by
  `--force-recreate` (commit `cf3ee0e`, "drop stable-path mounts").
- The `gatus-iframe` middleware (`frame-ancestors https://sentinel.imapps.uk`) looks vestigial: sentinel
  now fetches Gatus JSON instead of embedding it.
- cadvisor below 0.55 exports only `id="/"` on this Docker 29 + containerd-snapshotter host (see the
  compose comment).
- Vaultwarden sits on its own network, so Gatus checks it via the public route.
