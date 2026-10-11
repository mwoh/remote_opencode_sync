#!/usr/bin/env bash
# upgrade.sh — `roe upgrade`: refresh an existing roe project's sync layer to the
#   current toolkit's seed (non-destructive).
#
# What it refreshes, and only what is missing or drifted (never clobbers user
# content):
#   .opencode/toolkit            rewritten to the current marker content
#   opencode.json(c)             the fallback resume/handoff/sync command block is
#                                restored (model + existing keys preserved); if the
#                                "command" key exists but is incomplete it is left
#                                untouched and flagged for a manual merge
#   AGENTS.md                    workflow rules appended only if the `## 1. Session
#                                start` header is absent
#   .gitignore                   sync ignore patterns appended only if the marker is
#                                absent
#   session-logs/                created if missing (+ .gitkeep)
#
# It pulls first so the refresh + its commit sit on top of the latest round, and
# refuses to run while the working tree is dirty so it never bundles your work
# into the refresh commit. On a desynced copy (no-session-sync opt-out) it skips
# the AGENTS.md / .gitignore writes (skip-worktree pins would silently ignore them).
#
# Exit codes:
#   0   refreshed (committed + pushed) or nothing to update
#   1   not a roe project / not a git repo / dirty tree / identity missing /
#       pull or push failed
#
# Usage: upgrade.sh [dir] [--force-commands]
# Env:   none
#
# --force-commands refreshes the fallback command block even when it has no
# roe-managed marker (i.e. you believe the drift is just old wording, not your edits).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$ROOT_DIR/templates"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FORCE_COMMANDS=0
DIR=""
for a in "$@"; do
  case "$a" in
    --force-commands) FORCE_COMMANDS=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) DIR="$a" ;;
  esac
done
DIR="${DIR:-$PWD}"

# _refresh_command_block <config> — rebuild the project's opencode config from the
# shipped template's `$comment` + `command` block while preserving this project's own
# `model` pin. Rebuilding (rather than splicing the JSON in place) keeps it correct even
# if the project reordered keys or reformatted. Returns non-zero on failure so the caller
# advises instead of claiming a change it didn't make.
_refresh_command_block() {
  local cfg="$1" model block out
  model="$(model_get "$DIR" 2>/dev/null || true)"
  # the template's $comment + command block (everything from the marker to its closing brace)
  block="$(awk 'BEGIN{p=0} /"\$comment".*roe-managed/ {p=1} p{print} p && /^  \}/{exit}' \
    "$TEMPLATES_DIR/opencode.jsonc.tpl")"
  [[ -n "$block" ]] || return 1
  out="$(mktemp "${TMPDIR:-/tmp}/roe-cfg.XXXXXX")" || return 1
  {
    printf '{\n'
    printf '  "$schema": "https://opencode.ai/config.json",\n'
    if [[ -n "$model" ]]; then
      printf '  "model": "%s",\n' "$model"
    fi
    printf '%s\n' "$block"
    printf '}\n'
  } > "$out" || { rm -f "$out"; return 1; }
  mv "$out" "$cfg"
  return 0
}

if ! project_has_marker "$DIR"; then
  echo "roe upgrade: not a remote_opencode_sync project (no .opencode/toolkit marker)" >&2
  echo "  first make it one with: roe adopt <dir>" >&2
  exit 1
fi
if ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "roe upgrade: not inside a git repo" >&2
  exit 1
fi

if [[ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]]; then
  echo "roe upgrade: the working tree has uncommitted changes." >&2
  echo "  commit or stash them first — roe upgrade never bundles your work." >&2
  exit 1
fi

# ---- pull latest first: the refresh sits on the newest round ----
if git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  if ! git -C "$DIR" fetch origin >/dev/null 2>&1; then
    echo "roe upgrade: could not fetch origin (network?) — proceeding from local state." >&2
  else
    upstream="$(git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"
    behind="$(git -C "$DIR" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
    if [[ "${behind:-0}" != "0" ]]; then
      if ! git -C "$DIR" pull --rebase; then
        echo "roe upgrade: pull --rebase failed — resolve/abort and re-run." >&2
        exit 1
      fi
      echo "roe upgrade: pulled $behind commit(s) before refreshing."
    fi
  fi
fi

desynced=0
if project_desynced "$DIR"; then
  desynced=1
  echo "roe upgrade: desynced copy detected — refreshing marker/commands only."
  echo "  (AGENTS.md / .gitignore are skip-worktree pinned here; re-run resync to flip them back first)"
fi

CHANGED=0
REVIEW=0
note() { echo "  $*"; }
changed() { CHANGED=1; note "$*"; }
manual_review() { REVIEW=1; note "$*"; }

echo "roe upgrade — $DIR"

# ---- [1] marker ----
mkdir -p "$DIR/.opencode"
if [[ "$(cat "$DIR/.opencode/toolkit" 2>/dev/null || true)" != "remote_opencode_sync" ]]; then
  printf 'remote_opencode_sync\n' > "$DIR/.opencode/toolkit"
  changed "marker: restored .opencode/toolkit"
else
  note "marker: current"
fi

# ---- [2] opencode config commands ----
config=""
[[ -f "$DIR/opencode.json" ]] && config="$DIR/opencode.json"
[[ -z "$config" && -f "$DIR/opencode.jsonc" ]] && config="$DIR/opencode.jsonc"

if [[ -z "$config" ]]; then
  # no config at all → seed a fresh opencode.jsonc (model pinned if resolvable)
  config="$DIR/opencode.jsonc"
  cp "$TEMPLATES_DIR/opencode.jsonc.tpl" "$config"
  model="$(model_get "$DIR" 2>/dev/null || true)"
  [[ -z "$model" ]] && model="$(model_from_global 2>/dev/null || true)"
  if [[ -n "$model" ]]; then
    sed "s|@@MODEL@@|$model|" "$config" > "$config.tmp" && mv "$config.tmp" "$config"
  else
    grep -vF "@@MODEL@@" "$config" > "$config.tmp" && mv "$config.tmp" "$config"
  fi
  changed "commands: created $(basename "$config") (command block + $( [[ -n "$model" ]] && echo "model $model" || echo "no pinned model" ))"
elif project_commands_current "$DIR"; then
  # The keys are all present — but the BODIES may still be older wording than the
  # toolkit's (e.g. a project seeded before the /sync archive-freshness check). If the
  # block is marked roe-managed (the user didn't hand-edit it) we refresh it to the
  # current template so everyone converges; otherwise we only advise.
  drifted="$(project_commands_drift "$DIR" || true)"
  if [[ -z "$drifted" ]]; then
    note "commands: current in $(basename "$config")"
  elif [[ "$FORCE_COMMANDS" -eq 1 ]]; then
    # Explicit request: refresh even without the marker (the user is saying "this drift
    # is just old wording, not my edits").
    if _refresh_command_block "$config"; then
      changed "commands: refreshed the command block in $(basename "$config") (--force-commands)"
    else
      manual_review "commands: --force-commands could not rewrite $(basename "$config") — merge $TEMPLATES_DIR/opencode.jsonc.tpl manually"
    fi
  elif project_commands_managed "$DIR"; then
    if _refresh_command_block "$config"; then
      changed "commands: refreshed the roe-managed command block in $(basename "$config") (was stale: $(echo "$drifted" | tr '\n' ' ' | sed 's/ $//'))"
    else
      manual_review "commands: could not refresh the roe-managed block in $(basename "$config") — merge $TEMPLATES_DIR/opencode.jsonc.tpl manually"
    fi
  else
    manual_review "commands: $(basename "$config") has stale command wording ($(echo "$drifted" | tr '\n' ' ' | sed 's/ $//')) —"
    manual_review "  it has no roe-managed marker, so it looks hand-edited and was left alone."
    manual_review "  to adopt the current wording: roe upgrade --force-commands"
  fi
elif grep -qE '"command"[[:space:]]*:' "$config"; then
  manual_review "commands: 'command' key exists in $(basename "$config") but is incomplete —"
  manual_review "  merge the missing keys from $TEMPLATES_DIR/opencode.jsonc.tpl manually"
else
  # Scratch file goes in a temp dir with a trap, not inside the toolkit clone: an
  # interrupted upgrade used to leave `.upgrade-cmdblock.$$` there, which then made
  # `update.sh`'s `git checkout -- .` leave the toolkit tree dirty.
  block="$(mktemp "${TMPDIR:-/tmp}/roe-cmdblock.XXXXXX")"
  trap 'rm -f "$block"' EXIT
  awk 'BEGIN{p=0} /^  "command": \{/ {p=1} p {print} p && /^  \}$/ {exit}' "$TEMPLATES_DIR/opencode.jsonc.tpl" > "$block"
  # If the awk range ever matches nothing (template indentation change), injecting an
  # empty block would still be reported as a successful change.
  if [[ ! -s "$block" ]]; then
    manual_review "commands: could not extract the command block from the template —"
    manual_review "  merge $TEMPLATES_DIR/opencode.jsonc.tpl into $(basename "$config") manually"
  elif jsonc_inject_block "$config" "$block"; then
    changed "commands: injected fallback command block into $(basename "$config")"
  else
    manual_review "commands: failed to inject the command block into $(basename "$config") —"
    manual_review "  merge $TEMPLATES_DIR/opencode.jsonc.tpl manually"
  fi
  rm -f "$block"
  trap - EXIT
fi

# ---- [3] AGENTS.md rules ----
if [[ "$desynced" -eq 1 ]] || project_rules_current "$DIR"; then
  [[ "$desynced" -eq 1 ]] || note "rules: current (## 1. Session start present)"
elif [[ -f "$DIR/AGENTS.md" ]]; then
  printf '\n\n' >> "$DIR/AGENTS.md"
  cat "$TEMPLATES_DIR/workflow-rules.md.tpl" >> "$DIR/AGENTS.md"
  changed "rules: appended workflow rules to AGENTS.md"
  manual_review "rules: review the appended block in AGENTS.md (keeping only what you want)"
else
  cp "$TEMPLATES_DIR/AGENTS.md.tpl" "$DIR/AGENTS.md"
  sed "s/{{PROJECT_NAME}}/$(basename "$DIR")/g" "$DIR/AGENTS.md" > "$DIR/AGENTS.md.tmp" && mv "$DIR/AGENTS.md.tmp" "$DIR/AGENTS.md"
  changed "rules: created AGENTS.md from the workflow template"
fi

# ---- [4] .gitignore sync patterns ----
if [[ "$desynced" -eq 1 ]] || project_gitignore_current "$DIR"; then
  [[ "$desynced" -eq 1 ]] || note "ignore: current (remote_opencode_sync marker present)"
elif [[ -f "$DIR/.gitignore" ]]; then
  printf '\n' >> "$DIR/.gitignore"
  cat "$TEMPLATES_DIR/.gitignore.append.tpl" >> "$DIR/.gitignore"
  changed "ignore: appended sync patterns to .gitignore"
else
  cp "$TEMPLATES_DIR/.gitignore.append.tpl" "$DIR/.gitignore"
  changed "ignore: created .gitignore from the sync patterns"
fi

# ---- [5] session log directory ----
mkdir -p "$DIR/session-logs"
[[ -f "$DIR/session-logs/.gitkeep" ]] || touch "$DIR/session-logs/.gitkeep"

# ---- commit + push what changed ----
if [[ "$desynced" -eq 1 ]]; then
  note "desynced: not committing (this copy is opted out by design)"
  exit 0
fi

if [[ "$CHANGED" -eq 0 ]]; then
  note "nothing to update — this project already matches the current roe seed."
  exit 0
fi

if ! git -C "$DIR" config user.email >/dev/null 2>&1 || ! git -C "$DIR" config user.name >/dev/null 2>&1; then
  echo "roe upgrade: git user identity is not set for the commit." >&2
  echo "  run:  git config user.name \"Your Name\"   &&   git config user.email \"you@example.com\"" >&2
  exit 1
fi

git -C "$DIR" add -A
if ! git -C "$DIR" commit -m "chore: refresh remote_opencode_sync project seed (roe upgrade)"; then
  echo "roe upgrade: commit failed unexpectedly." >&2
  exit 1
fi

if git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  if ! git -C "$DIR" push --follow-tags 2>/dev/null && ! git -C "$DIR" push >/dev/null 2>&1; then
    echo "roe upgrade: refresh committed, but the push failed (network?)." >&2
    echo "  push it yourself: git -C $DIR push" >&2
    exit 1
  fi
fi

note "committed + pushed the refresh."
if [[ "$REVIEW" -eq 1 ]]; then
  note "  review the items flagged above before relying on the refreshed seed."
fi
exit 0