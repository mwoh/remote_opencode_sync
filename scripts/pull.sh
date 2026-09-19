#!/usr/bin/env bash
# pull.sh — `roe pull`: sync a roe project's working copy with the latest round.
#
# Mirrors the session-start ritual the global plugin runs (fetch, then a clean
# `pull --rebase`, stashing any local dirt and popping it back). Manual
# counterpart to /resume for when the plugin is off or you want explicit control.
#
# Exit codes:
#   0   pulled / already up to date
#   1   not a roe project, or pull/rebase failed (see the message)
#
# Usage: pull.sh [dir]   (default: current directory)
# Env:   none

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DIR="${1:-$PWD}"

if ! project_has_marker "$DIR"; then
  echo "roe pull: not a remote_opencode_sync project (no .opencode/toolkit marker)" >&2
  exit 1
fi
if ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "roe pull: not inside a git repo" >&2
  exit 1
fi
if ! git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  echo "roe pull: no git origin configured" >&2
  exit 1
fi

upstream="$(git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"
if [[ -z "$upstream" ]]; then
  echo "roe pull: no upstream tracked for HEAD — push it first: git push -u origin HEAD" >&2
  exit 1
fi

if ! git -C "$DIR" fetch origin; then
  echo "roe pull: could not fetch origin (network?). Nothing changed." >&2
  exit 1
fi

behind="$(git -C "$DIR" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
if [[ "${behind:-0}" == "0" ]]; then
  echo "roe pull: already up to date with $upstream"
  exit 0
fi

dirty="$(git -C "$DIR" status --porcelain 2>/dev/null)"
stashed=0
if [[ -n "$dirty" ]]; then
  if ! git -C "$DIR" stash push -m "roe pull: pre-pull" >/dev/null 2>&1; then
    echo "roe pull: could not stash $dirty local change(s) — stash them manually and re-run." >&2
    exit 1
  fi
  stashed=1
  echo "roe pull: stashed $dirty local change(s)"
fi

if ! git -C "$DIR" pull --rebase; then
  echo
  echo "roe pull: pull --rebase failed — you may need to resolve a conflict." >&2
  echo "  finish with: git pull --rebase --continue" >&2
  if [[ "$stashed" -eq 1 ]]; then
    echo "  then restore your work with: git stash pop" >&2
  fi
  exit 1
fi

if [[ "$stashed" -eq 1 ]]; then
  if ! git -C "$DIR" stash pop >/dev/null 2>&1; then
    echo "roe pull: pulled, but restoring the stash conflicted." >&2
    echo "  resolve it with: git stash pop" >&2
  fi
fi

echo "roe pull: pulled latest from $upstream"
exit 0