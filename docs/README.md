# Infra docs — index

Knowledge base for how everything we run is deployed and wired together. Two independent stacks, documented separately because they share no infrastructure:

- **[`homelab.md`](./homelab.md)** — the Dokploy homelab (`imapps.uk`): everything in this `foundry` repo, single host, Cloudflare tunnel + Access, NFS storage.
- **[`taisei-karate.md`](./taisei-karate.md)** — `taisei-karate`'s AWS deployment (sibling repo): Astro static site on S3 + CloudFront via Terraform, GitHub Actions OIDC, no servers.

```mermaid
flowchart LR
    subgraph home["Dokploy homelab (imapps.uk)"]
        direction TB
        h1["Single host `foundry`<br/>Docker Compose via Dokploy"]
    end

    subgraph aws["taisei-karate (AWS)"]
        direction TB
        a1["S3 + CloudFront<br/>via Terraform, no servers"]
    end

    note(["No shared DNS, auth, secrets,<br/>or deploy pipeline between the two"]):::note

    home -.- note -.- aws

    classDef note fill:#f2f0ea,stroke:#c8102e,color:#141414,stroke-dasharray: 3 3;
```

## Secrets

**Vaultwarden is live** at `vault.imapps.uk` (deployed 2026-08-23, `infra` project — see [`homelab.md` §5](./homelab.md#5-projects--services-dokploy-inventory)), pinned `1.37.2`, NFS-backed, no SMTP. Owner account + TOTP 2FA done, `ADMIN_TOKEN` set (Argon2id hash, admin panel confirmed gated), `SIGNUPS_ALLOWED=false`.

Remaining steps (not yet done):
1. Migrate `~/notes/secrets/tokens.md` and the two real `.env` files in via the `bw` CLI, then retire the plaintext `tokens.md`.
2. Add `pull-env.sh` to each app repo for local secret retrieval.

`taisei-karate`'s secrets stay as GitHub Actions secrets regardless (OIDC model, see [`taisei-karate.md` §5](./taisei-karate.md#5-secrets--auth-model)) — Vaultwarden is for personal/homelab credentials, not CI secrets.

## Keeping this current

These docs are only useful if they don't drift from what's actually deployed. When you change something (new service, port, domain, IAM policy, whatever):

1. Make the change (compose file / Terraform / Cloudflare config).
2. Update the relevant doc in this directory **in the same session**, not as a follow-up.
3. If it's a new finding rather than a change (e.g. an exposed port you noticed), add it to `../SECURITY-AUDIT.md` instead of just mentioning it in chat — chat context doesn't survive between sessions, these files do.

If a doc and the real infra disagree, the real infra wins — fix the doc, don't assume the doc was right.
