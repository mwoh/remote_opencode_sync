#!/usr/bin/env bash
# push.sh — `roe push`: push this roe project's committed state to its origin.
#
# The outbound half of the cross-device sync (inbound is `roe pull`). Pushes the
# current branch to its upstream; refuses to push when the remote is ahead
# (non-fast-forward) so you don't clobber round-trips made elsewhere.
#
# Exit codes:
#   0   pushed / nothing to push
#   1   not a roe project, remote ahead, or the push failed (see the message)
#
# Usage: push.sh [dir]   (default: current directory)
# Env:   none

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DIR="${1:-$PWD}"

if ! project_has_marker "$DIR"; then
  echo "roe push: not a remote_opencode_sync project (no .opencode/toolkit marker)" >&2
  exit 1
fi
if ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "roe push: not inside a git repo" >&2
  exit 1
fi
if ! git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  echo "roe push: no git origin configured" >&2
  exit 1
fi

upstream="$(git -C "$DIR" rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"
if [[ -z "$upstream" ]]; then
  echo "roe push: no upstream tracked for HEAD — push it first: git push -u origin HEAD" >&2
  exit 1
fi

if ! git -C "$DIR" fetch origin >/dev/null 2>&1; then
  echo "roe push: could not fetch origin (network?)." >&2
  exit 1
fi

behind="$(git -C "$DIR" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
if [[ "${behind:-0}" != "0" ]]; then
  echo "roe push: the remote is ahead by $behind commit(s) — pull first:" >&2
  echo "  roe pull   (fetches and rebases your work on top of the remote)" >&2
  exit 1
fi

ahead="$(git -C "$DIR" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)"
if [[ "${ahead:-0}" == "0" ]]; then
  echo "roe push: nothing to push ($DIR is up to date with $upstream)"
  exit 0
fi

if ! git -C "$DIR" push; then
  echo "roe push: push failed (network?). Your commits are safe locally." >&2
  exit 1
fi

echo "roe push: pushed $ahead commit(s) to $upstream"
exit 0