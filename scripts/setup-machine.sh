#!/usr/bin/env bash
# setup-machine.sh — lazy one-time setup for a new machine.
# The companion doc is docs/machine-setup.md (read that first for context).
#
# What it does:
#   1. Checks/installs prerequisites: git, gh, node, opencode
#   2. gh auth login (interactive)
#   3. Generates an SSH key and registers it with GitHub
#   4. Installs the global session-sync plugin
#
# Note: this is the "lazy version". If you want to see exactly what it does, read
# docs/machine-setup.md. Prerequisite installs may prompt for sudo or a package
# manager password.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_SRC="$ROOT_DIR/plugins/session-sync.js"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FAILED=0
warn() { echo "  ! $*" >&2; }
ok() { echo "  + $*"; }
banner() { echo; echo "== $* =="; }

ensure_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    ok "$name: $(command -v "$name")"
  elif pkg_install "$name"; then
    ok "$name: installed via package manager"
  else
    warn "$name missing and I can't install it automatically"
    warn "  → install $name manually, then re-run this script"
    FAILED=1
  fi
}

banner "Prerequisites"
ensure_tool git
ensure_tool gh
ensure_tool node

banner "opencode"
if command -v opencode >/dev/null 2>&1; then
  ok "opencode: $(command -v opencode)"
elif command -v npm >/dev/null 2>&1; then
  npm install -g opencode-ai && ok "opencode: installed via npm"
elif curl -fsSL https://opencode.ai/install | bash; then
  ok "opencode: installed via install script"
else
  warn "opencode could not be installed automatically"
  warn "  → run: curl -fsSL https://opencode.ai/install | bash"
  FAILED=1
fi

banner "GitHub authentication"
if gh auth status >/dev/null 2>&1; then
  ok "already authenticated"
else
  echo "  (login via browser or paste a token when prompted)"
  gh auth login
fi

banner "SSH key"
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -C "$(whoami)@$(hostname)" -f "$HOME/.ssh/id_ed25519"
  ok "generated ~/.ssh/id_ed25519"
fi
KEY_FINGERPRINT="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" 2>/dev/null | awk '{print $2}')"
if gh ssh-key list 2>/dev/null | grep -q "$KEY_FINGERPRINT"; then
  ok "SSH key already registered on GitHub"
else
  gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$(hostname)-opencode" \
    && ok "SSH key registered on GitHub (title: $(hostname)-opencode)" \
    || warn "could not register SSH key — add $HOME/.ssh/id_ed25519.pub to GitHub manually"
fi

banner "Git identity"
if git config --global user.email >/dev/null 2>&1 && git config --global user.name >/dev/null 2>&1; then
  ok "already configured: $(git config --global user.name) <$(git config --global user.email)>"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  local login GH_NAME GH_EMAIL
  login="$(gh api user --jq .login 2>/dev/null || true)"
  GH_NAME="$(gh api user --jq '.name // empty' 2>/dev/null || true)"
  [[ -n "$GH_NAME" ]] || GH_NAME="$login"
  GH_EMAIL="$(gh api user --jq '.email // empty' 2>/dev/null || true)"
  [[ -n "$GH_EMAIL" ]] || GH_EMAIL="$login@users.noreply.github.com"
  git config --global user.name "$GH_NAME"
  git config --global user.email "$GH_EMAIL"
  ok "set global git identity: $GH_NAME <$GH_EMAIL>"
else
  warn "git identity not set — do it manually:"
  warn "  git config --global user.name 'Your Name'; git config --global user.email 'you@example.com'"
fi

banner "session-sync plugin"
if [[ -f "$HOME/.config/opencode/plugins/session-sync.js" ]]; then
  ok "plugin already installed"
else
  mkdir -p "$HOME/.config/opencode/plugins"
  cp "$PLUGIN_SRC" "$HOME/.config/opencode/plugins/session-sync.js"
  ok "installed $PLUGIN_SRC → ~/.config/opencode/plugins/session-sync.js"
fi

banner "Verify"
for cmd in git gh node opencode; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  $cmd: $("$cmd" --version 2>&1 | head -n 1)"
  else
    warn "$cmd still missing"
    FAILED=1
  fi
done

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "Setup complete. Next: git clone any project and opencode into it."
else
  echo "Setup finished WITH WARNINGS — see the '!' lines above."
  exit 1
fi