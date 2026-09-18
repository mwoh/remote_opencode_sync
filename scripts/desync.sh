#!/usr/bin/env bash
# desync.sh — remove THIS machine's copy of a project from the remote_opencode_sync
# sync loop, WITHOUT touching the repo or any other machine.
#
#   desync.sh [-y|--yes]     stop this working copy from syncing (run in project dir)
#
# What it does (both local-only, both reversible with `roe resync`):
#   1. Writes .opencode/state/no-session-sync (gitignored) — the global session-sync
#      plugin becomes a no-op in this working copy.
#   2. Removes the sync-rules block from the LOCAL working copy of AGENTS.md (keeps
#      the header + Project overview), and pins that local edit with
#      `git update-index --skip-worktree` so it can never be committed or pushed.
#
# Deliberately left alone (committed, so the repo + other machines keep them):
#   AGENTS.md rules in the repo, opencode.jsonc commands + pinned model, the
#   .opencode/toolkit marker, CONTINUE.md, session-logs/, .env.example. They stay
#   identical here so git stays clean — this machine simply stops acting on them.
#
# From the moment desync runs, this copy no longer pulls or pushes with the sync:
# it is frozen out of the collaboration while everyone else keeps going.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) echo "usage: desync.sh [-y|--yes]   (run in the project directory)"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; echo "usage: desync.sh [-y|--yes]" >&2; exit 1 ;;
  esac
done

PROJECT_DIR="$(pwd)"

# ---- guards ----
if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $PROJECT_DIR is not inside a git work tree" >&2
  exit 1
fi
if [[ ! -f "$PROJECT_DIR/.opencode/toolkit" ]]; then
  echo "error: no .opencode/toolkit marker in $PROJECT_DIR — not a remote_opencode_sync project." >&2
  exit 1
fi

STATE="$PROJECT_DIR/.opencode/state/no-session-sync"
if [[ -f "$STATE" ]]; then
  echo "$PROJECT_DIR is already desynced (found .opencode/state/no-session-sync)."
  echo "  undo with: roe resync"
  exit 0
fi

# ---- what will we do? ----
AGENTS="$PROJECT_DIR/AGENTS.md"
AGENTS_TRACKED=0
if git -C "$PROJECT_DIR" ls-files --error-unmatch AGENTS.md >/dev/null 2>&1; then
  AGENTS_TRACKED=1
fi
RULES_LINE=""
if [[ -f "$AGENTS" ]] && [[ "$AGENTS_TRACKED" -eq 1 ]]; then
  RULES_LINE="$(grep -nE '^## 1\. Session start' "$AGENTS" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  echo "This stops remote_opencode_sync from acting in $PROJECT_DIR on THIS machine only."
  echo "  - plugin neutralized via .opencode/state/no-session-sync (gitignored)"
  if [[ -n "$RULES_LINE" ]]; then
    echo "  - sync rules removed from the LOCAL AGENTS.md (pinned so they are never pushed)"
  else
    echo "  - no recognized rules block in AGENTS.md — it will be left unchanged"
  fi
  echo "The repo and other machines are untouched. Undo anytime with: roe resync"
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in
    y|Y|yes) ;;
    *) echo "aborted"; exit 1 ;;
  esac
fi

# ---- 1. plugin opt-out (gitignored) ----
mkdir -p "$PROJECT_DIR/.opencode/state"
touch "$STATE"
echo "  wrote .opencode/state/no-session-sync (plugin no-op in this copy)"

if ! git -C "$PROJECT_DIR" check-ignore -q .opencode/state/no-session-sync; then
  if [[ -f "$PROJECT_DIR/.gitignore" ]] && ! grep -qxF '.opencode/state/' "$PROJECT_DIR/.gitignore"; then
    printf '\n# added by roe desync (machine-local)\n.opencode/state/\n' >> "$PROJECT_DIR/.gitignore"
    if git -C "$PROJECT_DIR" ls-files --error-unmatch .gitignore >/dev/null 2>&1; then
      git -C "$PROJECT_DIR" update-index --skip-worktree .gitignore
      echo "  note: added '.opencode/state/' to the LOCAL .gitignore (skip-worktree — won't be committed)"
    else
      echo "  note: added '.opencode/state/' to .gitignore (untracked file)"
    fi
  else
    echo "  note: .opencode/state/ is not gitignored here — the opt-out file could be committed by accident."
    echo "        add '.opencode/state/' to .gitignore."
  fi
fi

# ---- 2. strip the sync rules from the local AGENTS.md ----
if [[ -n "$RULES_LINE" ]]; then
  OVERVIEW_LINE="$(grep -nE '^## Project overview' "$AGENTS" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  title="$(head -n 1 "$AGENTS" | sed -E 's/ — Workflow Rules \(AGENTS\.md\)//')"
  tmp="$AGENTS.tmp.$$"
  {
    printf '%s\n\n' "$title"
    printf '%s\n' '_This working copy is detached from remote_opencode_sync (roe desync).'
    printf '%s\n' '_Sync rules removed locally only; the committed AGENTS.md keeps them for other machines._'
    printf '\n'
    if [[ -n "$OVERVIEW_LINE" ]]; then
      sed -n "${OVERVIEW_LINE},$((RULES_LINE - 1))p" "$AGENTS"
    else
      sed -n "2,$((RULES_LINE - 1))p" "$AGENTS"
    fi
  } > "$tmp"
  mv "$tmp" "$AGENTS"
  git -C "$PROJECT_DIR" update-index --skip-worktree AGENTS.md
  echo "  stripped sync rules from the local AGENTS.md (kept the Project overview)"
  echo "  pinned AGENTS.md with git update-index --skip-worktree (never committed/pushed)"
elif [[ "$AGENTS_TRACKED" -eq 0 ]] && [[ -f "$AGENTS" ]]; then
  echo "  note: AGENTS.md is not tracked by git — leaving it unchanged"
else
  echo "  note: AGENTS.md has no '## 1. Session start' block to strip — leaving it unchanged"
fi

# ---- verify ----
DIRTY="$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null || true)"
if [[ -n "$DIRTY" ]]; then
  echo
  echo "  note: the working tree is not clean:"
  printf '%s\n' "$DIRTY" | sed 's/^/    /'
  echo "  (the desync itself never commits or pushes; inspect the above before committing.)"
fi
echo
echo "Done. This machine is desynced from remote_opencode_sync from this point on."
echo "  undo: roe resync"