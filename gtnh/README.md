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
| Images | `itzg/minecraft-server:java21` (`TYPE: GTNH`, `GTNH_PACK_VERSION: 2.9.0-RC-1`, `pull_policy: missing`); `tailscale/tailscale:v1.104.2` sidecar, digest-pinned (`@sha256:b11583…`, go1.27.3, 2026-10-26) |
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

Pollution is disabled in the persistent volume's `/data/config/GregTech/Pollution.cfg`:
`B:"Activate Pollution"=false` (applied 2026-11-05). Restart `gtnh` after changing it.
The ignored local `config/` directory does not control the live server. Recheck this setting
after a modpack update that replaces configuration files.

## Health / monitoring

- Gatus: `GTNH (Minecraft)` → `tcp://gtnh.tail2d4575.ts.net:25565`, every 120s (group Apps).
  Resolves because blocky forwards `ts.net` to MagicDNS.
- No container healthcheck in the compose file.

## Backups

Server Utilities keeps ZIP backups in `/data/backups/`, containing `OmniSlop/`,
`serverutilities/`, and `visualprospecting/`. On 2026-11-05 the latest existing backup,
`2026-11-03-22-43-01.zip`, passed CRC validation and was restored with the server stopped.
The restored `OmniSlop/level.dat` matched the archive byte-for-byte before the world began ticking.
The previous world and auxiliary data remain in `/data/.pre-restore-20261105/`; an additional
rollback archive, including the previous pollution config, is at
`/mnt/tank/shared/backups/gtnh/pre-restore-20261105.tar.gz`.

`gtnh-backup.timer` runs nightly at **02:00 UTC** (persistent across downtime). Its service
runs `backups/bin/gtnh-backup.sh`: disable autosaving, flush the world, archive `OmniSlop/`,
`serverutilities/`, `visualprospecting/`, `config/`, and server properties/whitelist/ops to
`/mnt/tank/shared/backups/gtnh/`, then re-enable autosaving even if archiving fails.
Each successful backup is extracted to a temporary directory and checked for world data,
region files, and supporting state. After a passing drill, timestamped archives older than
seven days are pruned; manual `pre-restore-*` archives are excluded.

Installed and exercised 2026-11-05: `2026-11-05T092416Z.tar.gz` (320 MiB on disk),
restore drill passed with 53 overworld region files. Inspect with
`systemctl status gtnh-backup.timer` and `journalctl -u gtnh-backup.service`;
run manually with `sudo systemctl start gtnh-backup.service`.
Unit sources are in `backups/systemd/gtnh-backup.{service,timer}`.
The tailscale state volume is not backed up (re-auth with a new key if lost).

## Gotchas

- The `gtnh` tailnet node is a full peer and the tailnet ACL is allow-all, so a compromised mod jar
  reaches `foundry` on every port and the advertised `192.168.68.0/24` — `../SECURITY-AUDIT.md` #1 (HIGH, open).
- If the sidecar restarts, the server container loses its network namespace; restart `gtnh` after it.
  [INFERENCE from `network_mode: service:`; not observed]
- `gtnh-data` and the Server Utilities ZIPs are on the host disk. Nightly archives and the manual pre-restore archive are on the ZFS mirror, but still on the same host; there is no off-host copy.
