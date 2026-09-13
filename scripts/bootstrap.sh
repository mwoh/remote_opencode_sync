#!/usr/bin/env bash
# bootstrap.sh — one-liner entry point for installing/updating the toolkit on any machine.
#
#   curl -fsSL https://raw.githubusercontent.com/mwoh/remote_opencode_sync/main/scripts/bootstrap.sh | bash
#
# What it does:
#   1. Ensures curl + git (installs git via package manager if missing)
#   2. Clones the toolkit to ~/.local/share/remote_opencode_sync (idempotent; re-running
#      pulls latest = your update path)
#   3. Runs scripts/setup-machine.sh (prereqs, gh auth, SSH key, global session-sync plugin)
#   4. Substitutes your real GitHub handle into the @@GITHUB_USER@@ placeholders
#      in the local copy's README/docs
#
# Set OC_SYNC_DIR to override the install location.

set -euo pipefail

REPO_URL="https://github.com/mwoh/remote_opencode_sync.git"
INSTALL_DIR="${OC_SYNC_DIR:-$HOME/.local/share/remote_opencode_sync}"

echo "== remote_opencode_sync bootstrap =="
echo "  install dir: $INSTALL_DIR"

# --- curl ---
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required. Install it and re-run this script." >&2
  exit 1
fi

# --- git (needed before we can clone) ---
if ! command -v git >/dev/null 2>&1; then
  echo ">> git not found — installing it..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y git
  elif command -v brew >/dev/null 2>&1; then
    brew install git
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm git
  else
    echo "error: could not auto-install git. Install it manually, then re-run." >&2
    exit 1
  fi
fi

# --- clone or update ---
if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo ">> Toolkit found — updating..."
  # discard any placeholder substitutions made on a previous run so ff-only pull works
  git -C "$INSTALL_DIR" checkout -- . 2>/dev/null || true
  git -C "$INSTALL_DIR" pull --ff-only
else
  echo ">> Cloning toolkit..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

# --- run setup ---
echo ">> Running setup-machine.sh..."
"$INSTALL_DIR/scripts/setup-machine.sh"

# --- link placeholders to the real GitHub handle ---
echo ">> Linking @@GITHUB_USER@@ placeholders to your GitHub account..."
# shellcheck source=lib.sh
source "$INSTALL_DIR/scripts/lib.sh"
relink_placeholders "$INSTALL_DIR"

echo
echo "Done. Toolkit at: $INSTALL_DIR"
echo "  New project?  $INSTALL_DIR/scripts/new-project.sh <repo-name>"
echo "  Update later? re-run this same script (pull + idempotent setup)"