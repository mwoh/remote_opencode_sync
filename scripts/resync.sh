#!/usr/bin/env bash
# resync.sh — undo `roe desync`: brings a working copy back into the sync loop.
# Run in the project directory.

set -euo pipefail

PROJECT_DIR="$(pwd)"
changed=0

STATE="$PROJECT_DIR/.opencode/state/no-session-sync"
if [[ -f "$STATE" ]]; then
  rm -f "$STATE"
  echo "  removed .opencode/state/no-session-sync (plugin active again)"
  changed=1
fi

if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # un-pin + restore AGENTS.md if desync stripped the local copy
  if git -C "$PROJECT_DIR" ls-files --error-unmatch AGENTS.md >/dev/null 2>&1 \
     && git -C "$PROJECT_DIR" ls-files -v | grep -q '^S AGENTS.md'; then
    git -C "$PROJECT_DIR" update-index --no-skip-worktree AGENTS.md
    git -C "$PROJECT_DIR" checkout -- AGENTS.md
    echo "  restored AGENTS.md from the repo (rules back)"
    changed=1
  fi
  # un-pin .gitignore if desync pinned a local ignore line
  if git -C "$PROJECT_DIR" ls-files -v | grep -q '^S .gitignore'; then
    git -C "$PROJECT_DIR" update-index --no-skip-worktree .gitignore
    git -C "$PROJECT_DIR" checkout -- .gitignore
    echo "  restored .gitignore from the repo"
    changed=1
  fi
fi

if [[ "$changed" -eq 0 ]]; then
  echo "$PROJECT_DIR was not desynced — nothing to do."
  exit 0
fi

echo
echo "Done. This working copy is back in the sync loop; it pulls/reconciles at the"
echo "next session start."