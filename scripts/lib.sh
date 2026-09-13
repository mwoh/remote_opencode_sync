#!/usr/bin/env bash
# lib.sh — shared helpers for remote_opencode_sync scripts.
# Source it from other scripts:  source "$(dirname "$0")/lib.sh"
# (No shebang requirements besides bash; exported as-is.)

PLACEHOLDER="@@GITHUB_USER@@"

# relink_placeholders <root_dir> [gh_user]
#   Replaces the @@GITHUB_USER@@ placeholder in *.md files under root_dir with the
#   user's real GitHub handle (guessed via gh/GITHUB_USER, else prompted). Non-fatal.
relink_placeholders() {
  local root_dir="$1"
  local gh_user=""
  if [[ -n "${2:-}" ]]; then
    gh_user="$2"
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh_user="$(gh api user --jq .login 2>/dev/null || true)"
  fi
  [[ -z "$gh_user" && -n "${GITHUB_USER:-}" ]] && gh_user="$GITHUB_USER"
  if [[ -z "$gh_user" ]]; then
    read -r -p "  GitHub username for README/docs links: " gh_user
  fi
  if [[ -n "$gh_user" ]]; then
    grep -rlF "$PLACEHOLDER" --include="*.md" "$root_dir" 2>/dev/null | while read -r f; do
      sed "s|$PLACEHOLDER|$gh_user|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done
  else
    echo "  (skipped — could not determine GitHub username)"
  fi
}

# detect_installer — echoes the detected package manager name, or empty string.
detect_installer() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt-get"
  elif command -v brew >/dev/null 2>&1; then echo "brew"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"
  else echo ""; fi
}

# pkg_install <pkg_name> — installs via the detected package manager. Returns non-zero on failure.
pkg_install() {
  local name="$1"
  local inst; inst="$(detect_installer)"
  case "$inst" in
    apt-get) sudo apt-get install -y "$name" ;;
    brew) brew install "$name" ;;
    dnf) sudo dnf install -y "$name" ;;
    pacman) sudo pacman -S --noconfirm "$name" ;;
    *) return 1 ;;
  esac
}