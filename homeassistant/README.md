# homeassistant

Home Assistant core, reached through Traefik at `home-assistant.imapps.uk`. Sentinel's API holds a
long-lived HA token. Inventory row: [`homelab.md` §5 `infra`](../docs/homelab.md#infra).

| | |
|---|---|
| Dokploy | project `infra`, compose `home-assistant` (`infra-homeassistant-hpyuzo`), path `homeassistant/docker-compose.yml` |
| Image | `ghcr.io/home-assistant/home-assistant:2024.12.3` (pinned, ~2 years old — `../SECURITY-AUDIT.md` #7) |
| Ports | `8123`, not host-published |
| Ingress | Dokploy domain `home-assistant.imapps.uk` → `homeassistant:8123`, HTTPS/letsencrypt. Cloudflare Access: covered by the wildcard require-email app (remote only); on LAN/tailnet HA's own login is the only gate ([`homelab.md` §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny)) |
| Networks | compose declares only its own `homeassistant` bridge; Dokploy attaches `dokploy-network` for the domain (observed live) |
| Volumes | `ha-config` → `/config`, bind to `/mnt/tank/shared/homeassistant/config`; `./configuration.yaml` bind-mounted over `/config/configuration.yaml` (so it is git-managed) |
| Env | none |
| Privileges | none — `privileged` and `NET_ADMIN`/`NET_RAW` removed 2026-10-10 (`../SECURITY-AUDIT.md`, closed) |

## Config

`configuration.yaml` keeps `default_config:` and sets `http.use_x_forwarded_for: true` with
`trusted_proxies` limited to loopback and `10.0.1.0/24` (the `dokploy-network` overlay subnet).
Do not add LAN/tailnet ranges — any host there could forge `X-Forwarded-For`. Everything else
(integrations, `.storage/`) lives in the bind-mounted config dir and is managed in the HA UI.

## Deploy / change

Commit + push, then `compose-deploy` — [`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change).
Upgrade in steps and read the breaking-changes notes for each release (`../SECURITY-AUDIT.md` #7).

## Health / monitoring

- Gatus: `Home Assistant` → `http://homeassistant:8123/manifest.json` (group Core).
- No container healthcheck in the compose file.

## Backups

`backups/config/homeassistant.sh`, nightly, 14 retained: tar of `/mnt/tank/shared/homeassistant/config`
excluding `deps/` and the recorder DB (`home-assistant_v2.db*`). Restore drill checks
`configuration.yaml`, `.storage/` and that `core.config_entries` has at least one entry
([`homelab.md` §9](../docs/homelab.md#9-backups--restore-drill)).

## Gotchas

- `.storage` registries were reset on 2026-08-20: only `sun` + `go2rtc` remain, TP-Link is gone, and
  the recorder has no history of the old entities ([`homelab.md` §10](../docs/homelab.md#10-gotchas-checklist-for-future-agents)).
- Bridge networking means Kasa/Tapo UDP broadcast discovery cannot work; add plugs by IP (live KLAP
  devices `192.168.68.9`, `.11`, `.14`) with the TP-Link account credentials.
- Since 2026-09-22 every WiFi device takes the LAN path and bypasses Access, so HA's own auth is the
  only protection on-LAN.
