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

# pkg_remove <pkg_name> — uninstalls via the detected package manager. Returns non-zero on failure.
pkg_remove() {
  local name="$1"
  local inst; inst="$(detect_installer)"
  case "$inst" in
    apt-get) sudo apt-get remove -y "$name" ;;
    brew) brew uninstall "$name" ;;
    dnf) sudo dnf remove -y "$name" ;;
    pacman) sudo pacman -R --noconfirm "$name" ;;
    *) return 1 ;;
  esac
}

# --- Uninstall manifest helpers -------------------------------------------
# The manifest is a plain key=value file (no jq dependency) written to a
# location OUTSIDE the toolkit clone, so it survives an uninstall that removes
# the clone itself. Set MANIFEST=<path> before sourcing these.
#
# Semantic:
#   mf_set        — write/replace a key (facts that refresh each run)
#   mf_keep       — write a key only if absent (first-run facts, preserve later)
#   mf_installed  — like mf_keep, but if a previous run recorded 'yes' (we
#                   installed it), keep 'yes' even if it looks pre-existing now
#                   (re-runs of setup must not forget what we installed).

mf_set() {
  local key="$1" val="${2:-}"
  grep -v "^${key}=" "$MANIFEST" > "$MANIFEST.tmp" 2>/dev/null || true
  mv "$MANIFEST.tmp" "$MANIFEST" 2>/dev/null || true
  printf '%s=%q\n' "$key" "$val" >> "$MANIFEST"
}

mf_keep() {
  local key="$1" val="${2:-}"
  grep -q "^${key}=" "$MANIFEST" 2>/dev/null || printf '%s=%q\n' "$key" "$val" >> "$MANIFEST"
}

mf_installed() {
  local key="$1" val="$2"
  if grep -q "^${key}=yes$" "$MANIFEST" 2>/dev/null; then
    return 0
  fi
  mf_set "$key" "$val"
}