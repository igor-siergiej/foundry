# Vaultwarden Secrets Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **This plan is not a candidate for autonomous subagent-driven execution** — several steps require the human owner's master password / admin token, which must never enter agent context. Every step is tagged **[USER]** or **[AGENT]**; an executing agent must stop and wait at every [USER] step rather than attempt it.

**Goal:** Finish bootstrapping the already-deployed Vaultwarden instance (`vault.imapps.uk`), migrate the real secrets currently sitting in plaintext (`~/notes/secrets/tokens.md`, two untracked `.env` files) into it, and wire up a repeatable local retrieval path for build-time secrets.

**Architecture:** Vaultwarden server already running (`foundry` repo, `infra` project, container healthy). Migration uses the official `bw` CLI pointed at the self-hosted server — never bitwarden.com. Each source file becomes one Secure Note item holding the file's full contents (simplest reliable round-trip: `bw get notes "<name>" > file` reconstructs it exactly). Retrieval for local builds is a tiny per-repo script, run manually by the user (never by the agent — it requires an unlocked `BW_SESSION`).

**Tech Stack:** Vaultwarden `1.37.2` (Docker, Dokploy-managed), Bitwarden CLI (`bw`), bash, `jq`.

**Spec:** This conversation — no separate spec doc. Key prior decisions it encodes:
- Vaultwarden replaces `~/notes/secrets/tokens.md`, not the Resilio-synced kanban/notes vault (those stay as-is).
- No SMTP, TOTP 2FA only (avoids the email-2FA bypass class behind CVE fixed in `1.35.4`).
- `ADMIN_TOKEN` must be an Argon2id-PHC hash, entered directly into Dokploy's env panel by the user — never through git, never through agent/chat context.
- The agent (Claude) does not hold a standing vault-unlock session. Any `bw unlock`/`BW_SESSION` step is user-only.

## Global Constraints

- No plaintext secret value (master password, admin token, vault item contents) may appear in agent chat/tool-call context at any point in this plan.
- `ADMIN_TOKEN` env var must be the Argon2id hash, not plaintext — Vaultwarden warns/rejects plaintext since v1.28.
- All `bw` CLI commands that touch real secret values are run by the user in their own terminal, not dispatched by the agent via Bash.
- Vaultwarden stays pinned at `1.37.2` in `foundry/vaultwarden/docker-compose.yml` — do not silently bump to `:latest`.
- Every infra-affecting change gets committed + pushed to `foundry` (Dokploy deploys from GitHub HEAD, not local files) and the relevant `foundry/docs/*.md` updated in the same pass (per `docs/README.md`'s "keeping this current" rule).

---

### Task 1: Bootstrap the owner account + TOTP 2FA

**Files:** none (browser-only).

**Interfaces:**
- Produces: one Vaultwarden account on `vault.imapps.uk`, TOTP enabled — required by every later task.

- [ ] **Step 1 [USER]:** Open `https://vault.imapps.uk` in a browser, click "Create Account". Use a strong, unique master password you don't reuse anywhere else — this is the one password everything else now depends on. Do not reuse your GitHub, email, or any existing Bitwarden password.
- [ ] **Step 2 [USER]:** Log in. Go to Account Settings → Security → Two-step Login → Authenticator App (TOTP). Scan the QR code with an authenticator app (not stored only on the same device as the browser you're using — a phone authenticator app is fine). Save the recovery code it shows you somewhere durable (e.g. write it down, don't screenshot into a synced photo library).
- [ ] **Step 3 [USER]:** Log out, log back in, confirm the TOTP prompt appears and a valid code from your authenticator app gets you in.
- [ ] **Step 4 [USER]:** Confirm to the agent that account + 2FA are done, so Task 2 can proceed.

---

### Task 2: Lock down the admin panel and close signups

**Files:**
- Modify (via Dokploy UI, not git): `vaultwarden` compose app's environment, `infra` project.

**Interfaces:**
- Consumes: nothing from Task 1's account credentials (admin token is independent of the user account).
- Produces: `ADMIN_TOKEN` set (Argon2 hash) and `SIGNUPS_ALLOWED=false` — required before Task 5/6 (real secrets go in) so the instance isn't left open to registration.

- [ ] **Step 1 [USER]:** SSH into the host and generate the Argon2id hash of a *new* admin password (separate from your account master password):

```bash
ssh home@home
env -u DOCKER_HOST docker run --rm -it vaultwarden/server:1.37.2 /vaultwarden hash
# prompts for a password (hidden input), prints a line starting $argon2id$...
```

  Copy the full `$argon2id$...` output line. This hash is safe to move around (it's one-way), but the admin password you typed to generate it is not — don't reuse it elsewhere.

- [ ] **Step 2 [USER]:** In the Dokploy web UI: Projects → `infra` → `vaultwarden` → Environment. Add a line:

```
ADMIN_TOKEN=<paste the $argon2id$... hash>
```

  and change the existing `SIGNUPS_ALLOWED` line from `true` to `false`. Save, then trigger a redeploy from the same UI (or tell the agent to redeploy via `compose-deploy` once you confirm the env is saved — the agent can trigger the redeploy since it never sees the hash, only that the save happened).

- [ ] **Step 3 [AGENT]:** Verify the admin panel is now gated and signups are closed, without ever reading the token value:

```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://vault.imapps.uk/admin
# expect a redirect/login prompt (302 or 200 with a login form), not a bare dashboard
```

  and confirm via `mcp__dokploy-mcp__compose-one` (composeId from Task setup) that `composeStatus` is `done` after the redeploy.

- [ ] **Step 4 [AGENT]:** Update `foundry/docs/README.md#secrets`: change the "remaining steps" list to check off account/2FA/admin-token/signups-closed, commit, push.

```bash
git add docs/README.md && git commit -m "docs: vaultwarden bootstrap complete (account, 2FA, admin token, signups closed)" && git push
```

---

### Task 3: Install and configure the Bitwarden CLI locally

**Files:**
- Create (local machine, not a repo): `~/bin/bw` or wherever the user keeps local tools.

**Interfaces:**
- Produces: a working `bw` CLI pointed at `vault.imapps.uk`, logged in — required by Tasks 4–6.

- [ ] **Step 1 [USER]:**

```bash
curl -Lo bw.zip https://vault.bitwarden.com/download/?app=cli\&platform=linux
unzip bw.zip && chmod +x bw && mv bw ~/bin/   # or any dir on $PATH
bw --version
```

- [ ] **Step 2 [USER]:** Point it at the self-hosted server (not bitwarden.com) and log in:

```bash
bw config server https://vault.imapps.uk
bw login
```

- [ ] **Step 3 [USER]:** Confirm it's talking to the right server:

```bash
bw status | grep -i serverUrl
# expect "serverUrl":"https://vault.imapps.uk"
```

---

### Task 4: Write the migration helper script

**Files:**
- Create: `foundry/scripts/bw-import-file.sh`

**Interfaces:**
- Consumes: `BW_SESSION` env var (must already be exported by the user before running).
- Produces: one Secure Note item per invocation, name = first arg, content = file at second arg. Used by Tasks 5 and 6.

- [ ] **Step 1 [AGENT]:** Write the script:

```bash
#!/usr/bin/env bash
# bw-import-file.sh <item-name> <file-path>
# Stores <file-path>'s full contents as a Secure Note named <item-name>.
# Requires BW_SESSION already exported (run `export BW_SESSION=$(bw unlock --raw)` first).
set -euo pipefail

if [ -z "${BW_SESSION:-}" ]; then
  echo "BW_SESSION not set — run: export BW_SESSION=\$(bw unlock --raw)" >&2
  exit 1
fi

name="$1"
file="$2"

if [ ! -f "$file" ]; then
  echo "No such file: $file" >&2
  exit 1
fi

bw get template item | \
  jq --arg name "$name" --arg notes "$(cat "$file")" \
     '.type=2 | .name=$name | .secureNote={type:0} | .notes=$notes' | \
  bw encode | bw create item >/dev/null

echo "Created vault item: $name"
```

- [ ] **Step 2 [AGENT]:** `chmod +x foundry/scripts/bw-import-file.sh`

- [ ] **Step 3 [AGENT]:** Commit (script contains no secrets, safe to commit):

```bash
git add scripts/bw-import-file.sh && git commit -m "chore: add bw-import-file helper for secret migration" && git push
```

---

### Task 5: Migrate `tokens.md` into Vaultwarden

**Files:** none created (uses Task 4's script).

**Interfaces:**
- Consumes: `foundry/scripts/bw-import-file.sh` from Task 4.
- Produces: one vault item, `"homelab tokens (from tokens.md)"`.

- [ ] **Step 1 [USER]:**

```bash
export BW_SESSION=$(bw unlock --raw)
~/imapps/foundry/scripts/bw-import-file.sh "homelab tokens (from tokens.md)" ~/notes/secrets/tokens.md
```

- [ ] **Step 2 [USER]:** Verify round-trip before deleting anything:

```bash
bw sync
bw get notes "homelab tokens (from tokens.md)" | diff - ~/notes/secrets/tokens.md
# expect no output (files identical)
```

- [ ] **Step 3 [USER]:** Once the diff is clean, delete the plaintext file:

```bash
rm ~/notes/secrets/tokens.md
```

  (This is in the Resilio-synced notes vault, not git — no commit step. It'll disappear from other synced devices on next sync.)

---

### Task 6: Migrate the two real `.env` files

**Files:** none created (uses Task 4's script).

**Interfaces:**
- Consumes: `foundry/scripts/bw-import-file.sh` from Task 4.
- Produces: two vault items, `"jewellery-catalogue .env"` and `"mixtape .env"`.

- [ ] **Step 1 [USER]:** (reuse the same `BW_SESSION` from Task 5 if still valid, otherwise `export BW_SESSION=$(bw unlock --raw)` again)

```bash
~/imapps/foundry/scripts/bw-import-file.sh "jewellery-catalogue .env" ~/imapps/jewellery-catalogue/.env
~/imapps/foundry/scripts/bw-import-file.sh "mixtape .env" ~/imapps/mixtape/.env
```

- [ ] **Step 2 [USER]:** Verify both round-trip cleanly, same pattern as Task 5 Step 2:

```bash
bw sync
bw get notes "jewellery-catalogue .env" | diff - ~/imapps/jewellery-catalogue/.env
bw get notes "mixtape .env" | diff - ~/imapps/mixtape/.env
```

  Do **not** delete these local `.env` files — unlike `tokens.md`, they're needed on disk to actually run/build the apps. Vaultwarden is now the durable backup/source of truth; the local file stays for day-to-day dev.

---

### Task 7: Add the local pull-env script to each app repo

**Files:**
- Create: `jewellery-catalogue/scripts/pull-env.sh`
- Create: `mixtape/scripts/pull-env.sh`

**Interfaces:**
- Consumes: `BW_SESSION` (user-exported), the vault item names from Task 6.
- Produces: a one-command way to reconstruct `.env` from the vault on a fresh checkout or after local loss.

- [ ] **Step 1 [AGENT]:** Write the script (identical content, one per repo since they're independent git repos):

```bash
#!/usr/bin/env bash
# pull-env.sh — reconstructs .env from Vaultwarden. Run locally after
# `export BW_SESSION=$(bw unlock --raw)`. Vault item name must match
# what bw-import-file.sh used when this repo's .env was migrated in
# (see foundry/docs/superpowers/plans/2026-08-23-vaultwarden-secrets-migration.md).
set -euo pipefail

if [ -z "${BW_SESSION:-}" ]; then
  echo "BW_SESSION not set — run: export BW_SESSION=\$(bw unlock --raw)" >&2
  exit 1
fi

item_name="$1"   # e.g. "jewellery-catalogue .env"
bw get notes "$item_name" > .env
echo "wrote .env from vault item: $item_name"
```

- [ ] **Step 2 [AGENT]:** For each repo, commit the script (no secrets in it):

```bash
cd ~/imapps/jewellery-catalogue
git add scripts/pull-env.sh && git commit -m "chore: add pull-env.sh to restore .env from Vaultwarden" && git push

cd ~/imapps/mixtape
git add scripts/pull-env.sh && git commit -m "chore: add pull-env.sh to restore .env from Vaultwarden" && git push
```

- [ ] **Step 3 [USER]:** Verify each script works end to end on a scratch copy:

```bash
cd ~/imapps/jewellery-catalogue
mv .env .env.bak
export BW_SESSION=$(bw unlock --raw)   # if not already exported
./scripts/pull-env.sh "jewellery-catalogue .env"
diff .env .env.bak && rm .env.bak
```

  Repeat for `mixtape`. Expect no diff.

---

### Task 8: Close out the docs

**Files:**
- Modify: `foundry/docs/README.md`

**Interfaces:** none — final documentation sync, no code interfaces.

- [ ] **Step 1 [AGENT]:** Update the "Secrets" section in `docs/README.md`: mark the migration itself complete, list the vault item names created (`homelab tokens (from tokens.md)`, `jewellery-catalogue .env`, `mixtape .env`), and add a one-line pointer to `scripts/pull-env.sh` in each app repo for future onboarding.

- [ ] **Step 2 [AGENT]:** Commit and push:

```bash
git add docs/README.md && git commit -m "docs: vaultwarden secrets migration complete" && git push
```

- [ ] **Step 3 [USER]:** Rotate the Bitwarden `client_credentials` API key pasted into this chat earlier in the session (Account Settings → Security → Keys → Rotate API Key) — it's been in agent/transcript context since this conversation started and should be treated as burned regardless of whether it was ever actually used.
