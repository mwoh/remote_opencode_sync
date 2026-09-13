#!/usr/bin/env bash
# uninstall.sh — reverse of setup-machine.sh / the one-liner installer.
#
#   bash ~/.local/share/remote_opencode_sync/scripts/uninstall.sh
#
# Removes only what the install created, as recorded in the manifest written by
# setup-machine.sh (~/.local/state/remote_opencode_sync/uninstall.conf):
#   - the toolkit clone and the global session-sync plugin  (always, confirmed)
#   - the global git identity setup configured              (always, value-checked)
#   - optionally, per-tool, only packages that setup itself installed
#   - optionally, the gh login setup created
#   - optionally, the SSH key setup created (local + GitHub registration)
#
# By default (or with --yes) tools, gh auth, and the SSH key are KEPT — they're
# safe and may be useful elsewhere. A questionnaire (or flags) opts back in.
#
# Project files are NEVER touched. Per-project seeded files (AGENTS.md,
# CONTINUE.md, opencode.jsonc, .env.example, session-logs/) are left alone.

set -uo pipefail

STATE_DIR="${UNINSTALL_STATE_DIR:-$HOME/.local/state/remote_opencode_sync}"
MANIFEST="${UNINSTALL_MANIFEST:-$STATE_DIR/uninstall.conf}"

YES=0        # --yes: recommended defaults, no prompts
DRY_RUN=0    # --dry-run: preview only, no changes

# Recommended defaults: remove toolkit + plugin + identity; keep tools/auth/ssh.
DO_CLONE=1
DO_PLUGIN=1
DO_IDENTITY=1
DO_AUTH=0
DO_SSH=0
DO_TOOLS=0
R_GIT=0 R_GH=0 R_NODE=0 R_OPENCODE=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [options]

Removes the remote_opencode_sync toolkit from this machine. It reads the install
manifest (~/.local/state/remote_opencode_sync/uninstall.conf) written by
setup-machine.sh and removes only what the install created — anything you already
had is left untouched. Project files are never touched.

Options:
  --yes            take the recommended defaults, no prompts: remove the toolkit,
                   plugin, and any git identity setup set; KEEP tools, gh login,
                   and the SSH key
  --dry-run        preview what would be removed; make no changes
  --no-tools       never touch tool packages (git/gh/node/opencode)
  --no-auth        never log out of gh
  --no-ssh-key     never touch the SSH key
  --no-identity    never touch the git identity
  --no-plugin      keep the session-sync plugin
  --no-clone       keep the toolkit clone
  --conf <file>    use a different manifest path
  -h, --help       show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-tools) DO_TOOLS=0 ;;
    --no-auth) DO_AUTH=0 ;;
    --no-ssh-key) DO_SSH=0 ;;
    --no-identity) DO_IDENTITY=0 ;;
    --no-plugin) DO_PLUGIN=0 ;;
    --no-clone) DO_CLONE=0 ;;
    --conf) MANIFEST="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

warn() { echo "  ! $*" >&2; }
ok()   { echo "  + $*"; }

# say <cmd args…> — announce a step; only execute unless --dry-run. Returns cmd rc.
say() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  ~ (dry run) $*"
    return 0
  fi
  echo "  ~ $*"
  "$@"
}

# ask "prompt" <recommended default y|n> — non-interactive with --yes.
ANS=1
ask() {
  local prompt="$1" def="$2" ans hint
  ANS=1
  if [[ "$YES" -eq 1 ]]; then
    [[ "$def" == "yes" ]] && ANS=0
    return
  fi
  if [[ "$def" == "yes" ]]; then hint="Y/n"; else hint="y/N"; fi
  if ! read -r -p "  $prompt [$hint] " ans; then
    # EOF (non-tty): fall back to the recommended default
    [[ "$def" == "yes" ]] && ANS=0 || ANS=1
    return
  fi
  [[ -z "$ans" ]] && ans="$def"
  case "${ans,,}" in y|yes) ANS=0 ;; *) ANS=1 ;; esac
}

echo "== remote_opencode_sync uninstall =="
echo "  manifest: $MANIFEST"

HAS_MANIFEST=0
if [[ -f "$MANIFEST" ]]; then
  HAS_MANIFEST=1
  # shellcheck disable=SC1090
  source "$MANIFEST"
  echo "  installed at: ${INSTALL_DIR:-<unknown>} on ${INSTALLED_AT:-<unknown>}"
else
  warn "no manifest at $MANIFEST"
  warn "  this install predates uninstall support, so only the toolkit clone +"
  warn "  plugin can be safely attributed. Auth, SSH key, tools, and git identity"
  warn "  will be left alone (see the README for manual removal notes)."
fi

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share/remote_opencode_sync}"
PLUGIN_PATH="${PLUGIN_PATH:-$HOME/.config/opencode/plugins/session-sync.js}"

# ---- questionnaire (skipped entirely with --yes) -------------------------
if [[ "$YES" -eq 0 ]]; then
  echo
  echo "What should I remove? (blank = recommended default)"
  ask "Remove the toolkit itself + the session-sync plugin?" "yes"
  if [[ "$ANS" -ne 0 ]]; then
    echo "  Nothing to remove — exiting."
    exit 0
  fi

  if [[ "${GIT_NAME_SET:-no}" == "yes" || "${GIT_EMAIL_SET:-no}" == "yes" ]]; then
    ask "Remove the git identity setup configured earlier?" "yes"
    [[ "$ANS" -eq 0 ]] || DO_IDENTITY=0
  else
    DO_IDENTITY=0
  fi

  echo "  Tools installed BY SETUP (default: keep each):"
  [[ "${TOOL_GIT_INSTALLED:-no}" == "yes" ]]  && { ask "  remove 'git'?" "no";     [[ $ANS -eq 0 ]] && R_GIT=1; }
  [[ "${TOOL_GH_INSTALLED:-no}"  == "yes" ]]  && { ask "  remove 'gh'?" "no";      [[ $ANS -eq 0 ]] && R_GH=1; }
  [[ "${TOOL_NODE_INSTALLED:-no}" == "yes" ]] && { ask "  remove 'node'?" "no";    [[ $ANS -eq 0 ]] && R_NODE=1; }
  [[ "${OPENCODE_INSTALLED:-no}" == "yes" ]]  && { ask "  remove 'opencode'?" "no"; [[ $ANS -eq 0 ]] && R_OPENCODE=1; }

  if [[ "${GH_AUTH_INITIATED:-no}" == "yes" ]]; then
    ask "Log out of GitHub (gh auth) — created by setup?" "no"
    [[ "$ANS" -eq 0 ]] && DO_AUTH=1
  fi

  if [[ "${SSH_KEY_CREATED:-no}" == "yes" && "${SSH_KEY_REGISTERED:-no}" == "yes" ]]; then
    ask "Remove the SSH key setup created (local + GitHub registration)?" "no"
    [[ "$ANS" -eq 0 ]] && DO_SSH=1
  fi
else
  # --yes: defaults already set above (tools/auth/ssh kept)
  :
fi

# ---- summary --------------------------------------------------------------
echo
echo "== Summary =="
[[ "$DO_CLONE" -eq 1 ]]    && echo "  · toolkit clone:  $INSTALL_DIR"
[[ "$DO_PLUGIN" -eq 1 ]]   && echo "  · plugin:         $PLUGIN_PATH"
[[ "$DO_IDENTITY" -eq 1 ]] && echo "  · git identity:   unset (values match what setup set)"
[[ "$R_OPENCODE" -eq 1 ]]  && echo "  · opencode:       uninstall (recorded method: ${OPENCODE_METHOD:-script})"
[[ "$R_GH" -eq 1 ]]        && echo "  · gh:             remove package"
[[ "$R_GIT" -eq 1 ]]       && echo "  · git:            remove package"
[[ "$R_NODE" -eq 1 ]]      && echo "  · node:           remove package"
[[ "$DO_AUTH" -eq 1 ]]     && echo "  · gh auth:        logout"
[[ "$DO_SSH" -eq 1 ]]      && echo "  · SSH key:        deregister + delete"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  (dry run — nothing will change)"
fi

if [[ "$YES" -eq 0 ]]; then
  ask "Proceed?" "yes"
  [[ "$ANS" -eq 0 ]] || { echo "  Aborted."; exit 1; }
fi

[[ "$DRY_RUN" -eq 1 ]] || echo
echo "  Remember: close any running opencode sessions first."

# ---- removal (dependency order) ------------------------------------------
# 1. plugin
if [[ "$DO_PLUGIN" -eq 1 && -f "$PLUGIN_PATH" ]]; then
  say rm -f "$PLUGIN_PATH"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    rmdir "$(dirname "$PLUGIN_PATH")" 2>/dev/null || true
  fi
  ok "removed plugin"
fi

# 2. git identity — only if current value still matches what we set
if [[ "$DO_IDENTITY" -eq 1 ]]; then
  if [[ "${GIT_NAME_SET:-no}" == "yes" && -n "${GIT_NAME_VALUE:-}" ]]; then
    cur="$(git config --global user.name 2>/dev/null || true)"
    if [[ "$cur" == "$GIT_NAME_VALUE" ]]; then
      say git config --global --unset user.name 2>/dev/null || true
      ok "unset global user.name"
    else
      warn "user.name is now '$cur' (setup set '$GIT_NAME_VALUE') — leaving it alone"
    fi
  fi
  if [[ "${GIT_EMAIL_SET:-no}" == "yes" && -n "${GIT_EMAIL_VALUE:-}" ]]; then
    cur="$(git config --global user.email 2>/dev/null || true)"
    if [[ "$cur" == "$GIT_EMAIL_VALUE" ]]; then
      say git config --global --unset user.email 2>/dev/null || true
      ok "unset global user.email"
    else
      warn "user.email is now '$cur' (setup set '$GIT_EMAIL_VALUE') — leaving it alone"
    fi
  fi
fi

# 3. SSH key — deregister (needs gh + auth) before deleting, before tools/logout
if [[ "$DO_SSH" -eq 1 ]]; then
  if [[ "${SSH_KEY_REGISTERED:-no}" == "yes" ]]; then
    fp="${SSH_KEY_FINGERPRINT:-}"
    id="$(gh ssh-key list 2>/dev/null | awk -v fp="$fp" '$NF==fp {print $1; exit}')"
    if [[ -z "$id" && -n "${SSH_KEY_TITLE:-}" ]]; then
      id="$(gh ssh-key list 2>/dev/null | awk -v t="$SSH_KEY_TITLE" '$2==t {print $1; exit}')"
    fi
    if [[ -n "$id" ]]; then
      say gh ssh-key delete "$id" --yes || warn "could not deregister key (id $id)"
      ok "deregistered key id $id"
    else
      warn "registered key not found in 'gh ssh-key list' — skip deregistration"
    fi
  fi
  if [[ "${SSH_KEY_CREATED:-no}" == "yes" ]]; then
    say rm -f "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub"
    ok "removed SSH key files"
  else
    warn "SSH key pre-existed on this machine — local files left untouched"
  fi
fi

# 4. gh logout (before removing gh itself)
if [[ "$DO_AUTH" -eq 1 ]]; then
  [[ "${GH_AUTH_INITIATED:-no}" == "no" ]] && warn "gh login pre-existed — logging out per your choice"
  say gh auth logout || warn "gh auth logout failed — run it manually if still authed"
fi

# 5. opencode (npm uninstall must happen while node still exists)
if [[ "$R_OPENCODE" -eq 1 ]]; then
  case "${OPENCODE_METHOD:-script}" in
    npm) say npm uninstall -g opencode-ai || warn "npm uninstall of opencode failed" ;;
    *)
      say rm -rf "$HOME/.opencode"
      if [[ -f "$HOME/.local/bin/opencode" ]]; then say rm -f "$HOME/.local/bin/opencode"; fi
      echo "    (if the installer added a 'opencode' PATH line, remove it from ~/.bashrc, ~/.zshrc, …)"
      ;;
  esac
fi

# 6. tool packages — gh first, node last (so npm is still present until opencode is gone)
remove_pkg() {
  local pkg="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  ~ (dry run) pkg_remove $pkg"
    return 0
  fi
  if pkg_remove "$pkg"; then
    ok "removed package: $pkg"
  else
    warn "could not remove '$pkg' via package manager — remove it manually if desired"
  fi
}
[[ "$R_GH" -eq 1 ]]   && [[ "${TOOL_GH_INSTALLED:-no}" == "yes" ]] && remove_pkg gh
[[ "$R_GIT" -eq 1 ]]  && [[ "${TOOL_GIT_INSTALLED:-no}" == "yes" ]] && remove_pkg git
[[ "$R_NODE" -eq 1 ]] && [[ "${TOOL_NODE_INSTALLED:-no}" == "yes" ]] && remove_pkg node

# 7. the toolkit clone (guarded: only if it looks like a toolkit clone)
if [[ "$DO_CLONE" -eq 1 && -d "$INSTALL_DIR" ]]; then
  if [[ -f "$INSTALL_DIR/scripts/lib.sh" && -f "$INSTALL_DIR/plugins/session-sync.js" ]]; then
    say rm -rf "$INSTALL_DIR"
    ok "removed toolkit clone"
  else
    warn "refusing to delete $INSTALL_DIR — it does not look like a toolkit clone"
  fi
fi

# 8. the manifest — last, so reruns/aborts keep state
if [[ "$HAS_MANIFEST" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  ~ (dry run) rm -f $MANIFEST"
  else
    rm -f "$MANIFEST"
    rmdir "$STATE_DIR" 2>/dev/null || true
    ok "removed uninstall manifest"
  fi
fi

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete — no changes were made."
else
  echo "Uninstall complete."
  echo "  Project repos and any files you kept are untouched."
  echo "  Removed per-project sync files manually if you want them gone (see README)."
fi