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

### Task 4: Write the migration + retrieval helper scripts

**Files:**
- Create: `~/dotfiles/bin/.local/bin/bw-import-file` (stow package `bin`, symlinked to `~/.local/bin/bw-import-file`, already on `$PATH`)
- Create: `~/dotfiles/bin/.local/bin/pull-env` (same package/symlink mechanism)

Not per-repo — these are personal machine tools, not project code, so they
live in the dotfiles repo (stowed into `~/.local/bin`) rather than
duplicated into `foundry` or any app repo. `pull-env` is generic (`pull-env
<item-name> [out-file]`, defaults `out-file` to `.env`) so one copy serves
every repo, unlike a per-repo `scripts/pull-env.sh`.

**Interfaces:**
- Consumes: `BW_SESSION` env var (must already be exported by the user before running).
- `bw-import-file` produces: one Secure Note item per invocation, name = first arg, content = file at second arg. Used by Tasks 5 and 6.
- `pull-env` produces: reconstructs a vault item's contents to a local file. Used by Task 7.

- [ ] **Step 1 [AGENT]:** Write the scripts:

```bash
#!/usr/bin/env bash
# bw-import-file <item-name> <file-path>
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

```bash
#!/usr/bin/env bash
# pull-env <item-name> [out-file]
# Reconstructs a .env file from a Vaultwarden Secure Note. Run locally after
# `export BW_SESSION=$(bw unlock --raw)`. Vault item name must match what
# bw-import-file used when the file was migrated in.
set -euo pipefail

if [ -z "${BW_SESSION:-}" ]; then
  echo "BW_SESSION not set — run: export BW_SESSION=\$(bw unlock --raw)" >&2
  exit 1
fi

item_name="$1"
out_file="${2:-.env}"

bw get notes "$item_name" > "$out_file"
echo "wrote $out_file from vault item: $item_name"
```

- [ ] **Step 2 [AGENT]:** `chmod +x` both, add `bin` to `SHARED` in `~/dotfiles/Makefile`, `stow --target=$HOME --restow bin`.

- [ ] **Step 3 [AGENT]:** Commit in the dotfiles repo (script contains no secrets, safe to commit):

```bash
cd ~/dotfiles
git add bin/.local/bin/bw-import-file bin/.local/bin/pull-env Makefile README.md
git commit -m "chore: add bw-import-file + pull-env personal CLI scripts" && git push
```

---

### Task 5: Migrate `tokens.md` into Vaultwarden

**Files:** none created (uses Task 4's script).

**Interfaces:**
- Consumes: `bw-import-file` (on `$PATH`) from Task 4.
- Produces: one vault item, `"homelab tokens (from tokens.md)"`.

- [ ] **Step 1 [USER]:**

```bash
export BW_SESSION=$(bw unlock --raw)
bw-import-file "homelab tokens (from tokens.md)" ~/notes/secrets/tokens.md
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
- Consumes: `bw-import-file` (on `$PATH`) from Task 4.
- Produces: two vault items, `"jewellery-catalogue .env"` and `"mixtape .env"`.

- [ ] **Step 1 [USER]:** (reuse the same `BW_SESSION` from Task 5 if still valid, otherwise `export BW_SESSION=$(bw unlock --raw)` again)

```bash
bw-import-file "jewellery-catalogue .env" ~/imapps/jewellery-catalogue/.env
bw-import-file "mixtape .env" ~/imapps/mixtape/.env
```

- [ ] **Step 2 [USER]:** Verify both round-trip cleanly, same pattern as Task 5 Step 2:

```bash
bw sync
bw get notes "jewellery-catalogue .env" | diff - ~/imapps/jewellery-catalogue/.env
bw get notes "mixtape .env" | diff - ~/imapps/mixtape/.env
```

  Do **not** delete these local `.env` files — unlike `tokens.md`, they're needed on disk to actually run/build the apps. Vaultwarden is now the durable backup/source of truth; the local file stays for day-to-day dev.

---

### Task 7: Verify pull-env end to end

**Files:** none (uses Task 4's `pull-env`, on `$PATH` in every repo already).

**Interfaces:**
- Consumes: `BW_SESSION` (user-exported), the vault item names from Task 6.
- Produces: confirmation that `pull-env` reconstructs each `.env` byte-for-byte from the vault.

- [ ] **Step 1 [USER]:** Verify end to end on a scratch copy, per repo:

```bash
cd ~/imapps/jewellery-catalogue
mv .env .env.bak
export BW_SESSION=$(bw unlock --raw)   # if not already exported
pull-env "jewellery-catalogue .env"
diff .env .env.bak && rm .env.bak
```

  Repeat for `mixtape` with `pull-env "mixtape .env"`. Expect no diff.

---

### Task 8: Close out the docs

**Files:**
- Modify: `foundry/docs/README.md`

**Interfaces:** none — final documentation sync, no code interfaces.

- [ ] **Step 1 [AGENT]:** Update the "Secrets" section in `docs/README.md`: mark the migration itself complete, list the vault item names created (`homelab tokens (from tokens.md)`, `jewellery-catalogue .env`, `mixtape .env`), and add a one-line pointer to `pull-env` (in `~/dotfiles`, on `$PATH`) for future onboarding.

- [ ] **Step 2 [AGENT]:** Commit and push:

```bash
git add docs/README.md && git commit -m "docs: vaultwarden secrets migration complete" && git push
```

- [ ] **Step 3 [USER]:** Rotate the Bitwarden `client_credentials` API key pasted into this chat earlier in the session (Account Settings → Security → Keys → Rotate API Key) — it's been in agent/transcript context since this conversation started and should be treated as burned regardless of whether it was ever actually used.

---

### Task 9: Import browser-saved passwords

**Files:** none (browser + `bw` CLI only).

**Interfaces:** none — standalone, does not depend on Tasks 4-8's helper scripts (`bw import` covers this natively).

Original ask covered "all the secrets, in our browser, dokploy, local .env" —
Tasks 5/6 only migrated `tokens.md` and two `.env` files. Browser-saved
logins were never actually covered. This task closes that gap.

- [ ] **Step 1 [USER]:** Export saved passwords to CSV: Chrome
  `chrome://settings/passwords` → ⋮ → Export passwords; Firefox
  `about:logins` → ⋮ → Export Logins.
- [ ] **Step 2 [USER]:** Confirm `bw config server` still points at
  `https://vault.imapps.uk` (set in Task 3), then
  `export BW_SESSION=$(bw unlock --raw)`.
- [ ] **Step 3 [USER]:** Import: `bw import chromecsv <path-to-csv>` (or
  `firefoxcsv` — run `bw import --formats` for the full list).
- [ ] **Step 4 [USER]:** `bw sync`, spot-check the item count in the vault
  UI matches the browser's saved-password count.
- [ ] **Step 5 [USER]:** Shred the plaintext CSV immediately:
  `shred -u <path-to-csv>` (plain `rm` leaves recoverable disk blocks).

---

### Task 10: Dev-server env injection from Vaultwarden (no on-disk `.env`)

**Files:**
- Created: `~/dotfiles/bin/.local/bin/bw-run`, `~/dotfiles/bin/.local/bin/bw-run-compose` (done, see dotfiles `265ffdf`).

**Interfaces:**
- Consumes: `BW_SESSION` (user-exported), a vault item per repo (same names as Task 6's `bw-import-file` items).
- Produces: a way to run any repo's dev command with secrets injected into the process only — closes the original ask's "no .env files" goal, once each repo's real `.env` is actually migrated in (Task 6) and the on-disk file is deleted.

Generic, not per-repo — one pair of scripts covers every repo under `~/imapps`, same reasoning as Task 4.

- [x] **Step 1 [AGENT]:** Write `bw-run` — execs a command with a vault Secure Note's `KEY=VALUE` lines exported into that process only, nothing written to disk. Usage: `bw-run "kivo .env" -- bun run dev`.
- [x] **Step 2 [AGENT]:** Write `bw-run-compose` — same idea for `docker compose`, which needs an `--env-file` *path*: writes a private (`0600`) temp file for the call's duration, deletes it on exit. Usage: `bw-run-compose "mixtape .env" -- up`.
- [ ] **Step 3 [USER]:** Once a repo's `.env` is migrated in (Task 6) and verified (Task 7), delete the local `.env` and switch that repo's dev workflow to `bw-run`/`bw-run-compose`. Per repo, not all-at-once — do it as each one's migration lands.

**Note on Dokploy (prod) env vars — reviewed, not centralizing:** Dokploy's
per-app/compose environment panel is the actual deploy-time mechanism that
injects env vars into running prod containers — there's no Dokploy↔Vaultwarden
integration, so "centralizing" would mean either (a) a custom script pushing
Bitwarden → Dokploy via `dokploy-mcp` on every secret change, adding a new
failure mode to the deploy path for a homelab, or (b) manually keeping two
places in sync, which drifts. Recommendation: **keep Dokploy env vars in
Dokploy** as prod's source of truth (unchanged); optionally mirror a copy
into a Vaultwarden Secure Note per service as an off-host disaster-recovery
backup only (via `bw-import-file`, same pattern as `tokens.md`) — never a
live sync Dokploy reads from. Same boundary already drawn for
`taisei-karate`'s GitHub Actions secrets: Vaultwarden is for personal/homelab
credentials and DR backups, not a live secrets backend for a deploy
pipeline.
