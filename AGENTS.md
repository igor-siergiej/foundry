# foundry — homelab IaC

Docker Compose stacks for the `imapps.uk` Dokploy homelab, running on the host `foundry`.

## Before anything else
1. Run `homelab-status` to get the live state. Exit 1 means something is down. Add `--coverage` to list services that are unmonitored or undocumented. On machines where it isn't on PATH, it lives in dotfiles at `bin/.local/bin/homelab-status`.
2. Read [`docs/homelab.md`](./docs/homelab.md) for topology, the deploy flow, MCP access and the gotchas checklist. If it disagrees with `docker ps` or a live compose file, trust the live state and fix the doc.

## Hard rules
- Dokploy deploys from GitHub `main` HEAD. To change a compose file, commit, push (`dangerouslyDisableSandbox: true`), then run `compose-deploy` through `dokploy-mcp` explicitly. The autoDeploy webhook is unreliable.
- `blocky` is the whole LAN's DNS. Never leave it down.
- Never leave `BW_SESSION` exported beyond a single render step. Vaultwarden runs on this host.
- New service: add a Gatus endpoint in `monitoring/config/gatus/config.yaml` and a row in `docs/homelab.md` §5 in the same change.

## Layout
One directory per stack (`blocky/`, `monitoring/`, `immich/`, …), each with a `docker-compose.yml`. Security findings: `SECURITY-AUDIT.md`.
