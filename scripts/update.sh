#!/usr/bin/env bash
# update.sh — one-command updater for this toolkit when it's already installed.
#
#   ~/.local/share/remote_opencode_sync/scripts/update.sh
#
# Equivalent to re-running the bootstrap curl command:
# pull latest, re-run setup (refreshes the global session-sync plugin), re-link
# placeholders. Restart opencode afterward to load a refreshed plugin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ ! -d "$ROOT_DIR/.git" ]]; then
  echo "error: not inside the toolkit repo. Run this script from the toolkit clone." >&2
  exit 1
fi

ORIGIN="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
if [[ "$ORIGIN" != "https://github.com/mwoh/remote_opencode_sync.git" \
      && "$ORIGIN" != "git@github.com:mwoh/remote_opencode_sync.git" ]]; then
  echo "error: origin is '$ORIGIN' — not the official toolkit repo. Refusing to update." >&2
  exit 1
fi

echo ">> Discarding local placeholder edits..."
git -C "$ROOT_DIR" checkout -- . 2>/dev/null || true

echo ">> Pulling latest toolkit..."
git -C "$ROOT_DIR" pull --ff-only

echo ">> Re-running setup (refreshes the global session-sync plugin)..."
"$ROOT_DIR/scripts/setup-machine.sh"

echo ">> Re-linking placeholders..."
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"
relink_placeholders "$ROOT_DIR"

echo
echo "Update complete. Restart opencode to load the refreshed plugin."