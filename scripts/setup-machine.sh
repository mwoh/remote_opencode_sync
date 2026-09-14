#!/usr/bin/env bash
# setup-machine.sh — lazy one-time setup for a new machine.
# The companion doc is docs/machine-setup.md (read that first for context).
#
# What it does:
#   1. Checks/installs prerequisites: git, gh, node, opencode
#   2. gh auth login (interactive)
#   3. Generates an SSH key and registers it with GitHub
#   4. Sets a global git identity (from the GitHub profile, if missing)
#   5. Installs the global session-sync plugin
#   6. Installs the 'roe' command (symlink in ~/.local/bin + PATH entry for it)
#   7. Writes an uninstall manifest (~/.local/state/remote_opencode_sync/uninstall.conf)
#      recording exactly what THIS install created, so scripts/uninstall.sh can
#      remove it later without touching anything you already had.
#
# Note: this is the "lazy version". If you want to see exactly what it does, read
# docs/machine-setup.md. Prerequisite installs may prompt for sudo or a package
# manager password.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_SRC="$ROOT_DIR/plugins/session-sync.js"
PLUGIN_DST="$HOME/.config/opencode/plugins/session-sync.js"

STATE_DIR="${UNINSTALL_STATE_DIR:-$HOME/.local/state/remote_opencode_sync}"
MANIFEST="${UNINSTALL_MANIFEST:-$STATE_DIR/uninstall.conf}"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- uninstall manifest bookkeeping ---
mkdir -p "$STATE_DIR"
[[ -f "$MANIFEST" ]] || : > "$MANIFEST"
mf_set "MANIFEST_VERSION" "1"
mf_set "INSTALLED_AT" "$(date -Iseconds)"
mf_keep "INSTALL_DIR" "$ROOT_DIR"
mf_keep "PLUGIN_PATH" "$PLUGIN_DST"

FAILED=0
warn() { echo "  ! $*" >&2; }
ok() { echo "  + $*"; }
banner() { echo; echo "== $* =="; }

ensure_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    ok "$name: $(command -v "$name")"
    mf_installed "TOOL_${name^^}_INSTALLED" "no"
  elif pkg_install "$name"; then
    ok "$name: installed via package manager"
    mf_installed "TOOL_${name^^}_INSTALLED" "yes"
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
  mf_installed "OPENCODE_INSTALLED" "no"
  mf_keep "OPENCODE_METHOD" "existing"
elif command -v npm >/dev/null 2>&1; then
  npm install -g opencode-ai \
    && mf_installed "OPENCODE_INSTALLED" "yes" \
    || warn "opencode install via npm failed"
  ok "opencode: installed via npm"
  mf_keep "OPENCODE_METHOD" "npm"
elif curl -fsSL https://opencode.ai/install | bash; then
  ok "opencode: installed via install script"
  mf_installed "OPENCODE_INSTALLED" "yes"
  mf_keep "OPENCODE_METHOD" "script"
else
  warn "opencode could not be installed automatically"
  warn "  → run: curl -fsSL https://opencode.ai/install | bash"
  FAILED=1
fi

banner "GitHub authentication"
if gh auth status >/dev/null 2>&1; then
  ok "already authenticated"
  mf_installed "GH_AUTH_INITIATED" "no"
else
  echo "  (login via browser or paste a token when prompted)"
  gh auth login
  mf_installed "GH_AUTH_INITIATED" "yes"
fi

banner "SSH key"
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  mkdir -p "$HOME/.ssh"
  if ssh-keygen -t ed25519 -N "" -C "$(whoami)@$(hostname)" -f "$HOME/.ssh/id_ed25519" >/dev/null 2>&1; then
    ok "generated ~/.ssh/id_ed25519"
    mf_installed "SSH_KEY_CREATED" "yes"
  else
    warn "failed to generate an SSH key (~/.ssh may not be writable)"
    mf_installed "SSH_KEY_CREATED" "no"
  fi
else
  ok "found existing ~/.ssh/id_ed25519"
  mf_installed "SSH_KEY_CREATED" "no"
fi
KEY_FINGERPRINT="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" 2>/dev/null | awk '{print $2}')"
mf_keep "SSH_KEY_FINGERPRINT" "$KEY_FINGERPRINT"
SSH_KEY_TITLE="$(hostname)-opencode"
mf_keep "SSH_KEY_TITLE" "$SSH_KEY_TITLE"
if gh ssh-key list 2>/dev/null | grep -q "$KEY_FINGERPRINT"; then
  ok "SSH key already registered on GitHub"
  mf_installed "SSH_KEY_REGISTERED" "no"
else
  gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$SSH_KEY_TITLE" \
    && ok "SSH key registered on GitHub (title: $SSH_KEY_TITLE)" \
    && mf_installed "SSH_KEY_REGISTERED" "yes" \
    || warn "could not register SSH key — add $HOME/.ssh/id_ed25519.pub to GitHub manually"
fi

banner "Git identity"
if git config --global user.email >/dev/null 2>&1 && git config --global user.name >/dev/null 2>&1; then
  ok "already configured: $(git config --global user.name) <$(git config --global user.email)>"
  mf_installed "GIT_NAME_SET" "no"
  mf_installed "GIT_EMAIL_SET" "no"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  login="$(gh api user --jq .login 2>/dev/null || true)"
  GH_NAME="$(gh api user --jq '.name // empty' 2>/dev/null || true)"
  [[ -n "$GH_NAME" ]] || GH_NAME="$login"
  GH_EMAIL="$(gh api user --jq '.email // empty' 2>/dev/null || true)"
  [[ -n "$GH_EMAIL" ]] || GH_EMAIL="$login@users.noreply.github.com"
  git config --global user.name "$GH_NAME"
  git config --global user.email "$GH_EMAIL"
  ok "set global git identity: $GH_NAME <$GH_EMAIL>"
  mf_installed "GIT_NAME_SET" "yes"
  mf_keep "GIT_NAME_VALUE" "$GH_NAME"
  mf_installed "GIT_EMAIL_SET" "yes"
  mf_keep "GIT_EMAIL_VALUE" "$GH_EMAIL"
else
  warn "git identity not set — do it manually:"
  warn "  git config --global user.name 'Your Name'; git config --global user.email 'you@example.com'"
fi

banner "session-sync plugin"
if [[ -f "$PLUGIN_DST" ]]; then
  ok "plugin already installed"
  mf_installed "PLUGIN_INSTALLED" "no"
else
  mkdir -p "$(dirname "$PLUGIN_DST")"
  cp "$PLUGIN_SRC" "$PLUGIN_DST"
  ok "installed $PLUGIN_SRC → $PLUGIN_DST"
  mf_installed "PLUGIN_INSTALLED" "yes"
fi

banner "roe command"
mkdir -p "$HOME/.local/bin"
ROE_LINK="$HOME/.local/bin/roe"
ROE_TARGET="$ROOT_DIR/bin/roe"
if [[ -f "$ROE_TARGET" ]]; then
  ln -sfn "$ROE_TARGET" "$ROE_LINK"
  ok "$ROE_LINK -> $ROE_TARGET"
  mf_set "ROE_LINKED" "yes"
else
  warn "$ROE_TARGET missing — 'roe' not linked"
  mf_set "ROE_LINKED" "no"
fi

BASH_RC="$HOME/.bashrc"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if [[ -f "$BASH_RC" ]] && grep -qF "$PATH_LINE" "$BASH_RC"; then
  if grep -q "^ROE_PATH_EXPORTED=yes$" "$MANIFEST"; then
    ok "$BASH_RC still has the PATH line setup added"
    mf_keep "ROE_PATH_EXPORTED" "yes"
  else
    ok "$BASH_RC already has \$HOME/.local/bin on PATH (pre-existing — untouched)"
    mf_set "ROE_PATH_EXPORTED" "no"
  fi
elif [[ -f "$BASH_RC" ]]; then
  printf '\n# added by remote_opencode_sync setup (roe command)\n%s\n' "$PATH_LINE" >> "$BASH_RC"
  ok "added \$HOME/.local/bin to PATH in $BASH_RC"
  mf_set "ROE_PATH_EXPORTED" "yes"
  echo "  → run 'roe' from a new shell (or: source $BASH_RC)"
else
  warn "$BASH_RC not found — prepend $HOME/.local/bin to PATH yourself to use 'roe'"
  mf_set "ROE_PATH_EXPORTED" "no"
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
echo "  Uninstall manifest: $MANIFEST"
echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "Setup complete. Next: git clone any project and opencode into it."
  echo "To remove everything later: roe uninstall (or scripts/uninstall.sh)"
else
  echo "Setup finished WITH WARNINGS — see the '!' lines above."
  exit 1
fi