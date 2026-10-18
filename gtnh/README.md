# gtnh

GregTech: New Horizons (modded Minecraft 1.7.10) dedicated server, reachable only over the tailnet.
Inventory row: [`homelab.md` §5 `gtnh`](../docs/homelab.md#gtnh-game-server).

> `.gitignore` ignores everything in `gtnh/` except `docker-compose.yml` and this README. The other
> files in this directory (mods, `config/`, `server.properties`, jars, whitelist/ops JSON) are local
> leftovers from a pre-container server and are **not** what the running server uses — its state
> lives in the `gtnh-data` volume.

| | |
|---|---|
| Dokploy | project `gtnh`, compose `gtnh` (`gtnh-7tyaj9`), path `gtnh/docker-compose.yml` |
| Images | `itzg/minecraft-server:java21` (`TYPE: GTNH`, `GTNH_PACK_VERSION: 2.9.0-RC-1`, `pull_policy: missing`); `tailscale/tailscale:latest` sidecar (unpinned, `../SECURITY-AUDIT.md` #8) |
| Ingress | tailnet only: `gtnh.tail2d4575.ts.net:25565`. No Dokploy domain, no Traefik, no host ports |
| Networks | `gtnh` uses `network_mode: service:gtnh-tailscale`; the sidecar sits on the stack default network. Not on `dokploy-network` |
| Volumes | `gtnh-data` → `/data` (world + server config); `gtnh-tailscale-state` → `/var/lib/tailscale`. Both plain named volumes on the host disk (no bind to `/mnt/tank`) |
| Devices / caps | sidecar: `/dev/net/tun`, `NET_ADMIN`, `NET_RAW`, `TS_USERSPACE=false` |
| Env (Dokploy) | `TS_AUTHKEY_GTNH` (sidecar's `TS_AUTHKEY`) |

Server settings are all compose env (itzg image): 6G heap, `JVM_OPTS` with `@java9args.txt`, hard
difficulty, `LEVEL_TYPE: BIOMESOP`, `LEVEL: OmniSlop`, flight allowed, `WHITELIST` and `OPS` lists
inline, `CREATE_CONSOLE_IN_PIPE` + `stdin_open`/`tty` for console access.

## Deploy / change

Change the compose env (e.g. bump `GTNH_PACK_VERSION`), commit + push, then `compose-deploy` — see
[`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change). Adding a player
means editing `WHITELIST` in the compose file, not the local `whitelist.json`.

Console: `docker exec -i gtnh rcon-cli <command>` (the backup script uses `rcon-cli save-all flush`).

## Health / monitoring

- Gatus: `GTNH (Minecraft)` → `tcp://gtnh.tail2d4575.ts.net:25565`, every 120s (group Apps).
  Resolves because blocky forwards `ts.net` to MagicDNS.
- No container healthcheck in the compose file.

## Backups

`backups/config/gtnh.sh`, nightly with the rest of the suite ([`homelab.md` §9](../docs/homelab.md#9-backups--restore-drill)):
`rcon-cli save-all flush`, then an `alpine:3` sidecar with `--volumes-from gtnh` tars `data/world`,
`server.properties`, `whitelist.json`, `ops.json` to `/mnt/tank/shared/backups/gtnh/`. Retention 7 days.
The restore drill checks for `world/level.dat` and at least one `.mca` region file. The tailscale
state volume is not backed up (re-auth with a new key if lost).

## Gotchas

- The `gtnh` tailnet node is a full peer and the tailnet ACL is allow-all, so a compromised mod jar
  reaches `foundry` on every port and the advertised `192.168.68.0/24` — `../SECURITY-AUDIT.md` #1 (HIGH, open).
- If the sidecar restarts, the server container loses its network namespace; restart `gtnh` after it.
  [INFERENCE from `network_mode: service:`; not observed]
- `gtnh-data` is on the host disk, not the ZFS mirror; the nightly tar is the only copy on `tank`.
