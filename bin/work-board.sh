#!/usr/bin/env bash
# foundry/bin/work-board.sh
#
# One-tap wrapper around three jott / kanban skills. Each subcommand builds the
# matching prompt in a way that survives quoting hazards, then `exec`s claude
# with that prompt from the right repo cwd.
#
# Why this script exists: launching a board run used to mean copy-pasting a
# 200-word prompt into a fresh claude pane every time. That's brittle
# (word-of-mouth drift between how humans actually write it and what the skill
# expects), and one of the reasons the kanban board stays untouched for
# weeks. The Collie launcher rows (see launchers.toml in the same dir) tap into
# this script; the `/work-board` command-palette row does the same thing from
# inside any pane.
#
# Subcommands:
#   work-board <project>    run `kanban-worker` against one project's Backlog
#   work-board all          run `kanban-worker` against every project's Backlog
#   work-board refine       run `refining-kanban-captures` (global inbox)
#   work-board triage       run `triaging-blocked-cards` across every project
#   work-board refresh      regenerate the Collie launchers.toml (not a skill)
#
# Permission mode (KANBAN_WORKER_PERMISSION env var):
#   acceptEdits (default)  - file writes auto-approved, Bash prompts
#   bypass                 - claude --dangerously-skip-permissions
#   manual                 - claude --permission-mode manual (every tool prompts)
#   plan                   - read-only planning mode
#   auto                   - claude --permission-mode auto
#
# The default is `acceptEdits`, not `bypass`: a one-tap button should not
# silently run arbitrary shell. Bypass requires the operator to set
# KANBAN_WORKER_PERMISSION=bypass explicitly on this machine.

set -euo pipefail

# Where the jott checkouts live. Defaults to imapps on foundry (the repo root
# siblings). Override with KANBAN_CLI_REPO_ROOTS for other layouts.
REPO_ROOTS_DEFAULT="/home/home/imapps"
KANBAN_CLI_REPO_ROOTS="${KANBAN_CLI_REPO_ROOTS:-$REPO_ROOTS_DEFAULT}"

# Foundry repo = where refine/triage/refresh run from (the meta-board, not
# any one app repo).
FOUNDRY_REPO_DEFAULT="/home/home/imapps/foundry"
FOUNDRY_REPO="${FOUNDRY_REPO:-$FOUNDRY_REPO_DEFAULT}"

# Where regen-launchers.sh writes. Resolved through `herdr plugin config-dir`
# when herdr is on PATH; falls back to the dotfiles layout for fresh installs.
HERDR_COLLIE_CONFIG_DEFAULT="$HOME/.config/herdr/plugins/config/herdr.collie"
if command -v herdr >/dev/null 2>&1; then
  HERDR_COLLIE_CONFIG_DEFAULT="$(herdr plugin config-dir herdr.collie 2>/dev/null || echo "$HERDR_COLLIE_CONFIG_DEFAULT")"
fi
HERDR_COLLIE_CONFIG="${HERDR_COLLIE_CONFIG:-$HERDR_COLLIE_CONFIG_DEFAULT}"

# The companion regen script. Same directory as this script.
REGEN="${REGEN:-$(cd "$(dirname "$0")" && pwd)/regen-launchers.sh}"

usage() {
  cat >&2 <<EOF
usage: work-board <project|all|refine|triage|refresh>
   <project>   one jott project name (e.g. foundry, kivo, shoppingo)
   all         run kanban-worker across every project
   refine      turn jott Inbox captures into Backlog items
   triage      walk Blocked cards, ask one decision per card
   refresh     regenerate the Collie launchers.toml

env:
  KANBAN_WORKER_PERMISSION  acceptEdits (default) | bypass | manual | plan | auto
  KANBAN_CLI_REPO_ROOTS     dirs to scan for project checkouts
                            (default: $REPO_ROOTS_DEFAULT)
  FOUNDRY_REPO              foundry repo path (default: $FOUNDRY_REPO_DEFAULT)
  HERDR_COLLIE_CONFIG       plugin config dir (resolved via 'herdr plugin config-dir')
EOF
  exit 2
}

# Build the per-scope prompt. Always printf so quoting hazards (single
# quotes, dollar signs, backticks, backslashes — all common in `blocked_reason`
# payloads) round-trip verbatim.
build_prompt() {
  case "$1" in
    project)
      local project="$2"
      printf 'Use the kanban-worker skill on the jott project "%s".\n' "$project"
      printf 'Run from the project checkout: cd "%s" first, then "claude" with this prompt.\n' "$project"
      printf 'Resolve the checkout via: KANBAN_CLI_REPO_ROOTS="%s" kanban-cli resolve-repo "%s".\n' "$KANBAN_CLI_REPO_ROOTS" "$project"
      printf 'Do not implement anything tagged inbox, do not promote captures — Backlog only.\n'
      printf 'If you hit a usage-check pause, schedule a wakeup and stop, do not start a new item.\n'
      printf 'At the end of the session print a one-line "shipped / blocked" summary per item.\n'
      ;;
    all)
      printf 'Use the kanban-worker skill to drain every jott project'\''s Backlog.\n'
      printf 'One project at a time (do NOT background); iterate until every project'\''s Backlog is empty.\n'
      printf 'Run from each project'\''s checkout, not from foundry. Resolve each via:\n'
      printf '  KANBAN_CLI_REPO_ROOTS="%s" kanban-cli resolve-repo "<project>"\n' "$KANBAN_CLI_REPO_ROOTS"
      printf 'Skip projects whose Backlog is empty; do not skip ones with items.\n'
      printf 'If a usage-check pause fires, schedule a wakeup across ALL projects and stop.\n'
      printf 'End with one summary line per project: shipped: N, blocked: M, skipped: K.\n'
      ;;
    refine)
      printf 'Use the refining-kanban-captures skill on the global jott inbox.\n'
      printf 'No --project flag — operate on every Inbox capture, project-less or otherwise.\n'
      printf 'For project-hinted captures, route them to the matching jott project before refining.\n'
      printf 'For non-jott ideas, write into the local <notes_dir>/kanban/index.md (notes-kanban skill), then jott task rm.\n'
      printf 'Never auto-delete. Never promote a capture you have not investigated against its repo.\n'
      printf 'At the end print a table: capture# → promoted-to-project# (or dropped, or skipped).\n'
      ;;
    triage)
      printf 'Use the triaging-blocked-cards skill across every jott project.\n'
      printf 'No --project flag — gather every Blocked row, gather context, ask one question per card.\n'
      printf 'Apply answers with jott task set, then jott sync. Offer once to run kanban-worker on each\n'
      printf 'project that ended the triage with no Blocked cards left.\n'
      printf 'Never implement. Unblocked cards go back to Backlog for kanban-worker.\n'
      printf 'End with: cards reviewed / decisions applied / cards still blocked.\n'
      ;;
    refresh)
      printf 'not a claude prompt: regen-launchers.sh regenerates the launchers.toml.\n' >&2
      return 64
      ;;
    *)
      echo "build_prompt: unknown scope: $1" >&2
      return 2
      ;;
  esac
}

# Map KANBAN_WORKER_PERMISSION to a claude flag.
permission_args() {
  case "${KANBAN_WORKER_PERMISSION:-acceptEdits}" in
    acceptEdits) printf -- '--permission-mode acceptEdits\n' ;;
    bypass)
      printf -- '--permission-mode bypassPermissions\n'
      printf -- '--dangerously-skip-permissions\n'
      ;;
    manual) printf -- '--permission-mode manual\n' ;;
    plan)   printf -- '--permission-mode plan\n' ;;
    auto)   printf -- '--permission-mode auto\n' ;;
    dontAsk) printf -- '--permission-mode dontAsk\n' ;;
    *)
      echo "work-board: unknown KANBAN_WORKER_PERMISSION='$KANBAN_WORKER_PERMISSION' (want acceptEdits/bypass/manual/plan/auto/dontAsk)" >&2
      exit 2
      ;;
  esac
}

# Resolve a jott project name to its on-disk checkout. Mirrors
# `kanban-cli resolve-repo` semantics (scan each KANBAN_CLI_REPO_ROOTS dir,
# up to two levels, for a `.kanban-cli.json` whose `repoName` matches). Returns
# the first match on stdout, non-zero if none.
resolve_project_repo() {
  local project="$1"
  local root
  for root in $(echo "$KANBAN_CLI_REPO_ROOTS" | tr ':' ' '); do
    [ -d "$root" ] || continue
    while IFS= read -r cfg; do
      local name
      name="$(jq -r '.repoName // empty' "$cfg" 2>/dev/null || true)"
      if [ "$name" = "$project" ]; then
        dirname "$cfg"
        return 0
      fi
    done < <(find "$root" -mindepth 2 -maxdepth 4 -name '.kanban-cli.json' -print 2>/dev/null)
  done
  return 1
}

# Per-project launcher handler.
run_project() {
  local project="$1"
  local repo
  if ! repo="$(resolve_project_repo "$project")"; then
    echo "work-board: project '$project' has no checkout under KANBAN_CLI_REPO_ROOTS=$KANBAN_CLI_REPO_ROOTS" >&2
    echo "work-board: clone it first: kanban-cli clone '$project'" >&2
    exit 3
  fi

  local prompt
  prompt="$(build_prompt project "$project")"

  # printf then exec — never let the prompt touch a shell-quoted arg except
  # via claude's own argv handling. A `--` between claude and the prompt keeps
  # anything starting with a dash from being read as a flag.
  cd "$repo"
  # shellcheck disable=SC2046
  exec claude $(permission_args) -- "$prompt"
}

run_all() {
  local prompt
  prompt="$(build_prompt all)"

  # The "all" sweep runs from FOUNDRY_REPO so each sub-spawn is its own claude
  # session rooted in that project. Foundry is just the launch pad.
  cd "$FOUNDRY_REPO"
  # shellcheck disable=SC2046
  exec claude $(permission_args) -- "$prompt"
}

run_refine() {
  local prompt
  prompt="$(build_prompt refine)"

  # Refine is global — its cwd doesn't matter, but staying in FOUNDRY_REPO
  # matches "it's a foundry concern" and means jott operations share a
  # working dir with the rest of the homelab tooling.
  cd "$FOUNDRY_REPO"
  # shellcheck disable=SC2046
  exec claude $(permission_args) -- "$prompt"
}

run_triage() {
  local prompt
  prompt="$(build_prompt triage)"

  cd "$FOUNDRY_REPO"
  # shellcheck disable=SC2046
  exec claude $(permission_args) -- "$prompt"
}

run_refresh() {
  if [ ! -x "$REGEN" ]; then
    echo "work-board: regen-launchers.sh not found / not executable at: $REGEN" >&2
    exit 4
  fi
  exec "$REGEN"
}

main() {
  [ "$#" -ge 1 ] || usage

  case "$1" in
    -h|--help|help) usage ;;
    all)            run_all ;;
    refine)         run_refine ;;
    triage)         run_triage ;;
    refresh)        run_refresh ;;
    *)
      # Anything else is a project name. Validate it exists in jott, fail
      # fast on typos so a stray button press doesn't open a Claude session
      # against a nonexistent project.
      local projects
      projects="$(jott task projects --json 2>/dev/null | jq -r '.projects[].name' 2>/dev/null || true)"
      if ! printf '%s\n' "$projects" | grep -Fxq -- "$1"; then
        echo "work-board: '$1' is not a jott project. Available:" >&2
        printf '  %s\n' $projects >&2 || true
        exit 3
      fi
      run_project "$1"
      ;;
  esac
}

main "$@"
