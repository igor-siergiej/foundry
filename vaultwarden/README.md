# vaultwarden

Self-hosted Bitwarden-compatible vault at `vault.imapps.uk`: the single-user store for personal and
homelab credentials (smoke-test accounts, `bw-run` items). CLI tooling and the migration plan:
[`../docs/README.md#secrets`](../docs/README.md#secrets). Inventory row:
[`homelab.md` §5 `infra`](../docs/homelab.md#infra).

| | |
|---|---|
| Dokploy | project `infra`, compose `vaultwarden` (appName `compose-reboot-virtual-monitor-bsqgog` — auto-generated, not descriptive), path `vaultwarden/docker-compose.yml` |
| Image | `vaultwarden/server:1.37.4`, digest-pinned (`@sha256:efb3cd…`, 2026-10-26). Its Debian `ca-certificates` 20250419 still trusts the eMudhra intermediates; the fixed `20250419+deb13u1` arrives with the next upstream image build |
| Ports | `expose: 80` only, no host publish |
| Ingress | Dokploy domain `vault.imapps.uk` → `vaultwarden:80`, HTTPS/letsencrypt. No dedicated Access app is listed in [`homelab.md` §6](../docs/homelab.md#6-cloudflare-access-model-set-2026-default-deny), so remotely it falls under the wildcard require-email app [INFERENCE — not verified against Cloudflare]; on LAN/tailnet the vault login + 2FA is the only gate |
| Networks | compose declares only its own `vaultwarden` bridge; Dokploy attaches `dokploy-network` for the domain (observed live) |
| Volumes | `vaultwarden-data` → `/data`, bind to `/mnt/tank/shared/vaultwarden` (ZFS; the compose comment calls it "NFS-backed", it is a local bind) |
| Env | `ADMIN_TOKEN` (Dokploy env, Argon2id PHC hash). Fixed in compose: `DOMAIN`, `SIGNUPS_ALLOWED=false`, `SIGNUPS_VERIFY=true`, `INVITATIONS_ALLOWED=false`, `SHOW_PASSWORD_HINT=false`, `IP_HEADER=X-Forwarded-For`, `LOG_LEVEL=warn` |

No SMTP is configured.

## Deploy / change

Commit + push, then `compose-deploy` — [`homelab.md` §3](../docs/homelab.md#3-deploy-flow-critical--read-before-any-change).

- `ADMIN_TOKEN`: generate with `docker run --rm -it vaultwarden/server:1.37.4 /vaultwarden hash` and
  paste straight into Dokploy's env panel — never into the compose file, a doc, or chat.
- Bootstrapping a fresh vault: temporarily set `SIGNUPS_ALLOWED: "true"`, register, set it back.
  Leaving it on was a real finding (`../SECURITY-AUDIT.md`, closed 2026-10-10).

## Health / monitoring

- Gatus: `Vaultwarden` → `https://vault.imapps.uk/alive` (group Core). It uses the public route
  because the compose file isolates the container on its own network.
- No container healthcheck in the compose file.

## Backups

`backups/config/vaultwarden.sh`, nightly, 14 retained: SQLite `.backup` of `db.sqlite3` plus
`rsa_key.pem` and `icon_cache/`, tar'd. Restore drill runs `PRAGMA integrity_check` and requires at
least one row in `users` ([`homelab.md` §9](../docs/homelab.md#9-backups--restore-drill)). Backups are
on the same ZFS mirror (not off-host).

## Gotchas

- `/etc/hosts` on `foundry` pins `vault.imapps.uk` to the LAN IP, so Access checks run from the host
  take the LAN path — test the edge with `curl --resolve` ([`homelab.md` §10](../docs/homelab.md#10-gotchas-checklist-for-future-agents)).
- `IP_HEADER=X-Forwarded-For` is what makes login rate limiting see real client IPs behind Traefik.
- The share holding this data is NFS-exported rw to the whole tailnet CGNAT range
  (`../SECURITY-AUDIT.md` #2, HIGH, open).
