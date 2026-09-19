#!/usr/bin/env bash
# status.sh — `roe status`: is this a valid roe project, and what does it need?
#
# Read-only advisory: checks the toolkit marker, then reports the sync state of
# the working copy — pushes needed, pulls needed, divergence, uncommitted work,
# a local desync opt-out, seeded-file drift (upgrade) and toolkit updates — and
# names the exact command to run next. Requires no writes beyond a `git fetch`.
#
# Exit codes:
#   0   valid roe project, everything is current (nothing to do)
#   1   not a roe project / not a usable git working copy
#   2   valid roe project, but at least one action is needed (see the report)
#
# Usage: status.sh [dir]   (default: current directory)
# Env:   none

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DIR="${1:-$PWD}"

if ! project_has_marker "$DIR"; then
  echo "roe status — $DIR"
  echo "  not a remote_opencode_sync project (no .opencode/toolkit marker)"
  echo "  make it one with: roe adopt <dir>"
  exit 1
fi

need=0
line()  { printf '  %s\n' "$*"; }
add()   { need=1; }

echo "roe status — $DIR"
line "marker: ok (remote_opencode_sync)"

if project_desynced "$DIR"; then
  line "desynced on this machine (no-session-sync opt-out)"
  add
fi

# --- git plumbing state ---
if ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  line "not inside a git repo — sync is impossible (re-init or clone)"
  exit 1
fi
if ! git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  line "no git origin configured — sync is impossible"
  line "  add one with: git remote add origin <url> (or adopt with roe adopt)"
  exit 1
fi

upstream="$(git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"
if [[ -z "$upstream" ]]; then
  line "no upstream tracked for HEAD — push it first: git push -u origin HEAD"
  exit 1
fi

if ! git -C "$DIR" fetch origin >/dev/null 2>&1; then
  line "note: could not reach origin (offline?) — reporting against the last fetched state"
fi

ahead="$(git -C "$DIR" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)"
behind="$(git -C "$DIR" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
dirty_n="$(git -C "$DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
dirty_n="${dirty_n:-0}"

# --- the single most useful answer first ---
if [[ "$behind" -gt 0 && "$ahead" -gt 0 ]]; then
  line "state: diverged ($ahead ahead, $behind behind) — reconcile with: git pull --rebase"
  add
elif [[ "$behind" -gt 0 ]]; then
  line "state: behind by $behind — run: roe pull"
  add
elif [[ "$ahead" -gt 0 ]]; then
  line "state: ahead by $ahead — run: roe push"
  add
elif [[ "$dirty_n" -gt 0 ]]; then
  line "state: $dirty_n uncommitted change(s) — commit them, then push"
  add
else
  line "state: all caught up"
fi

if [[ "$ahead" -gt 0 ]]; then
  line "  push: $ahead commit(s) ahead of $upstream"
elif [[ "$behind" -gt 0 ]]; then
  line "  pull: $behind commit(s) behind $upstream"
fi
if [[ "$dirty_n" -gt 0 ]]; then
  line "  working tree: $dirty_n uncommitted change(s)"
fi

# --- seed drift: does the project's sync layer match the current toolkit? ---
if project_seed_stale "$DIR"; then
  line "seed: drifted from the current toolkit — run: roe upgrade"
  [[ ! -f "$DIR/opencode.json" && ! -f "$DIR/opencode.jsonc" ]] && \
    line "  (missing opencode config with the resume/handoff/sync commands)"
  add
fi

# --- toolkit update available on this machine? ---
v="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
latest="$(toolkit_latest_ver "$ROOT_DIR" 2>/dev/null || true)"
if [[ -n "$v" && -n "$latest" && "$(ver_gt "$latest" "$v")" == "1" ]]; then
  line "toolkit: installed $v, latest $latest — run: roe update"
  add
fi

# --- compact health summary (informational, never affects the exit code) ---
model="$(model_get "$DIR" 2>/dev/null || true)"
[[ -n "$model" ]] && line "model: $model"
plugin="$HOME/.config/opencode/plugins/session-sync.js"
if [[ -f "$plugin" ]]; then
  line "plugin: installed on this machine"
else
  line "plugin: not installed on this machine (install with: roe setup)"
fi
line "tracking: $upstream"

if [[ "$need" -eq 0 ]]; then
  line "all current — nothing to do."
  exit 0
fi
echo "  next: see the states above and run the named command(s)."
exit 2