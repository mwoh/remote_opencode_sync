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

# --- Toolkit version helpers ------------------------------------------------
# 'roe version' compares the installed toolkit against the latest release tag on
# its origin. Releases are always tagged vX.Y.Z (AGENTS.md cadence rule), so
# version detection is pure git + awk — no gh, jq, or network beyond ls-remote.

# ver_sort_max — reads lines on stdin (git ls-remote --tags output, or plain tag
#   names) and echoes the greatest vX.Y.Z name, or "" if none matched. Strips the
#   "<sha> TAB" prefix, the refs/tags/ prefix, and annotated-tag ^{} peels.
ver_sort_max() {
  awk '
    function key(s,   a, n, i, out) {   # "v1.5.10" -> zero-padded sortable key
      sub(/^v/, "", s)
      n = split(s, a, ".")
      for (i = 1; i <= n; i++) if (a[i] !~ /^[0-9]+$/) return ""   # not semver
      out = ""
      for (i = 1; i <= n; i++) out = out sprintf("%09d", a[i])
      return out
    }
    {
      s = $0
      sub(/^[0-9a-f]+[[:space:]]+/, "", s)   # drop "<sha> TAB"
      sub(/^refs\/tags\//, "", s)            # refs/tags/v1.5.10 -> v1.5.10
      sub(/\^\{\}$/, "", s)                  # annotated-tag peeled entry
      k = key(s)
      if (k == "") next
      if (bestk == "" || k > bestk) { bestk = k; best = s }
    }
    END { print best }
  '
}

# ver_gt <a> <b> — historic/legacy-free numeric vX.Y.Z compare. Echoes "1" if a >
#   b, else "0".
ver_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    sub(/^v/, "", a); sub(/^v/, "", b)
    na = split(a, A, "."); nb = split(b, B, ".")
    for (i = 1; i <= 3; i++) {
      va = (i <= na) ? A[i] : 0
      vb = (i <= nb) ? B[i] : 0
      if (va > vb) { print 1; exit }
      if (va < vb) { print 0; exit }
    }
    print 0
  }'
}

# toolkit_latest_ver <repo_dir> — echoes the greatest vX.Y.Z tag advertised by
#   the repo's origin, or "" (return 1) if there is no origin / no match / the
#   remote is unreachable (offline).
toolkit_latest_ver() {
  local dir="$1" origin="" out=""
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  [[ -z "$origin" ]] && return 1
  out="$(git ls-remote --tags "$origin" 2>/dev/null | ver_sort_max)"
  [[ -n "$out" ]] || return 1
  echo "$out"
}

# --- Project seed detection (roe status / roe upgrade) ----------------------
# These predicate helpers mirror exactly what new-project.sh seeds and what the
# plugin/scripts detect by, so "is this toolkit project current?" is the same
# question everywhere. All take a directory and return 0 for "yes", 1 for "no".

# project_has_marker <dir> — carries the committed .opencode/toolkit marker that
#   new-project.sh seeds (the canonical "this is a roe project" answer).
project_has_marker() {
  [[ -f "$1/.opencode/toolkit" ]] && grep -qF "remote_opencode_sync" "$1/.opencode/toolkit"
}

# project_desynced <dir> — the local (gitignored) opt-out that desync.sh writes.
project_desynced() {
  [[ -f "$1/.opencode/state/no-session-sync" ]]
}

# project_commands_current <dir> — at least one opencode config carries the full
#   fallback command set (resume / handoff / sync) that opencode.jsonc.tpl seeds.
project_commands_current() {
  local cfg f
  for cfg in opencode.json opencode.jsonc; do
    f="$1/$cfg"
    [[ -f "$f" ]] || continue
    grep -qE '"resume"[[:space:]]*:' "$f" && \
    grep -qE '"handoff"[[:space:]]*:' "$f" && \
    grep -qE '"sync"[[:space:]]*:' "$f" && return 0
  done
  return 1
}

# project_rules_current <dir> — AGENTS.md carries the sync-rules block that marks
#   a seeded project as current: either the `## 1. Session start` header of the
#   full AGENTS.md.tpl, or the `<!-- appended by remote_opencode_sync ... -->`
#   comment that workflow-rules.md.tpl / the append path write. (The append block
#   numbers its headers instead, so both markers must count or upgrade/status
#   would loop on a project restored by append.)
project_rules_current() {
  grep -qE '^## 1\. Session start' "$1/AGENTS.md" ||
    grep -qF 'appended by remote_opencode_sync' "$1/AGENTS.md"
}

# project_gitignore_current <dir> — .gitignore carries the sync-content marker that
#   .gitignore.append.tpl seeds.
project_gitignore_current() {
  grep -qF "# --- added by remote_opencode_sync ---" "$1/.gitignore"
}

# project_seed_stale <dir> — exits 0 (stale) if ANY part of the seeded sync layer
#   drifted; used by roe status to recommend `roe upgrade`. Marker itself is
#   checked separately (its absence means "not a roe project" at all).
project_seed_stale() {
  project_commands_current "$1" || return 0
  project_rules_current "$1" || return 0
  project_gitignore_current "$1" || return 0
  return 1
}

# jsonc_inject_block <file> <blockfile> — comment-aware JSON/JSONC injector
#   (generalizes the `model_set` insert): inserts the contents of <blockfile>
#   directly before the file's final closing brace, adding the separator comma
#   to the previous element (respecting trailing `//` comments, and ignoring
#   `//` inside quoted strings). <blockfile> is written verbatim. No-ops when the
#   file has no final `}`/`]`. Used by roe upgrade to restore the fallback
#   command block without a JSON tool.
jsonc_inject_block() {
  local file="$1" blockfile="$2"
  awk -v blk="$blockfile" '
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
      for (i = 1; i <= NR; i++) {
        if (i == prev) print buf[i]
        else if (i == last) {
          while ((getline b < blk) > 0) print b
          close(blk)
          print buf[last]
        } else print buf[i]
      }
    }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}