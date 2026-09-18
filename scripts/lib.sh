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

# --- Model pin helpers ------------------------------------------------------
# Each project's opencode.json(c) can carry a "model" key so every machine that
# clones the repo runs the same model (project config overrides the global one).
# new-project.sh seeds it; the 'roe model' command views/edits it.

# model_from_global — echoes the model from the user's global opencode config, or "".
model_from_global() {
  local cfg="$HOME/.config/opencode/opencode.json"
  [[ -f "$cfg" ]] || return 1
  grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null \
    | head -n1 | sed -E 's/.*"model"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}

# model_get <dir> — echoes the model pinned in a project's opencode config
#   (opencode.json wins over opencode.jsonc, matching opencode precedence), or "".
model_get() {
  local dir="$1" cfg
  for cfg in opencode.json opencode.jsonc; do
    if [[ -f "$dir/$cfg" ]]; then
      local v
      v="$(grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$dir/$cfg" 2>/dev/null \
        | head -n1 | sed -E 's/.*"model"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
      [[ -n "$v" ]] && { echo "$v"; return 0; }
    fi
  done
  return 1
}

# model_resolve <requested> — precedence: <requested> (from --model) > $MODEL_PIN
#   > the user's global opencode config model > an interactive prompt. Echoes the
#   model, or "" if unresolved (callers then omit the model line entirely rather
#   than seeding a broken placeholder).
model_resolve() {
  local requested="${1:-}" global_candidate="" line
  [[ -n "$requested" ]] || requested="${MODEL_PIN:-}"
  if [[ -n "$requested" ]]; then echo "$requested"; return 0; fi
  global_candidate="$(model_from_global)"
  if [[ -n "$global_candidate" ]]; then echo "$global_candidate"; return 0; fi
  if read -r -p "  Model id for this project (blank = don't pin one): " line; then
    [[ -n "$line" ]] && { echo "$line"; return 0; }
  fi
  return 1
}

# model_set <dir> <id> — pins the model in a project's opencode config: rewrites
#   an existing "model" key in place (preferring opencode.json, then opencode.jsonc),
#   or injects one before the closing brace; creates a minimal opencode.jsonc if
#   neither file exists. Echoes the file written.
model_set() {
  local dir="$1" model="$2" cfg="" tmp
  if [[ -f "$dir/opencode.json" ]]; then cfg="$dir/opencode.json"
  elif [[ -f "$dir/opencode.jsonc" ]]; then cfg="$dir/opencode.jsonc"
  fi
  if [[ -z "$cfg" ]]; then
    cfg="$dir/opencode.jsonc"
    printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "model": "%s"\n}\n' "$model" > "$cfg"
    echo "$cfg"
    return 0
  fi
  tmp="$cfg.tmp.$$"
  if grep -qE '"model"[[:space:]]*:[[:space:]]*"' "$cfg"; then
    sed -E "s|(\"model\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1$model\2|" "$cfg" > "$tmp"
  else
    awk -v model="$model" '
      # position of the first // comment that is not inside a string; 0 = none
      function cmtpos(s,   i, n, ch, in_str) {
        n = length(s); in_str = 0
        for (i = 1; i <= n; i++) {
          ch = substr(s, i, 1)
          if (in_str) {
            if (ch == "\\") i++
            else if (ch == "\"") in_str = 0
          } else {
            if (ch == "\"") in_str = 1
            else if (ch == "/" && substr(s, i + 1, 1) == "/") return i
          }
        }
        return 0
      }
      { buf[NR] = $0 }
      END {
        for (i = NR; i >= 1; i--) if (buf[i] ~ /[^[:space:]]/) { last = i; break }
        prev = last - 1
        while (prev >= 1 && buf[prev] ~ /^[[:space:]]*$/) prev--
        if (prev >= 1) {
          cpos = cmtpos(buf[prev])
          code = (cpos ? substr(buf[prev], 1, cpos - 1) : buf[prev])
          if (code !~ /,\s*$/) {
            if (cpos) buf[prev] = substr(buf[prev], 1, cpos - 1) "," substr(buf[prev], cpos)
            else buf[prev] = buf[prev] ","
          }
        }
        comma = (buf[last] ~ /^[[:space:]]*[}\]]/) ? "" : ","
        for (i = 1; i <= NR; i++) {
          if (i == prev) print buf[i]
          else if (i == last) { print "  \"model\": \"" model "\"" comma; print buf[i] }
          else print buf[i]
        }
      }' "$cfg" > "$tmp"
  fi
  mv "$tmp" "$cfg"
  echo "$cfg"
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