#!/usr/bin/env bash
# projects.sh — list the user's GitHub repos that carry remote_opencode_sync support,
# and clone one onto this machine.
#
#   projects.sh list [--refresh] [name...]     list synced projects
#   projects.sh clone <name> [--dir <path>]    clone a synced project
#
# Detection: a project is "synced" iff its repo root carries the committed
# `.opencode/toolkit` marker — the exact same marker the session-sync plugin gates
# on, so this list can never disagree with what actually runs.
#
# No jq dependency: gh's --template rendering handles the JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CACHE_TTL="${ROE_PROJECTS_TTL:-900}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/remote_opencode_sync"
CACHE_FILE="$CACHE_DIR/projects.json"
SCAN_ERR=""

usage() {
  cat <<EOF
projects.sh — list / clone remote_opencode_sync projects

Usage:
  projects.sh list [--refresh] [name...]
  projects.sh clone <name> [--dir <path>]

  list      show your GitHub repos that carry the .opencode/toolkit marker.
            Results are cached ${CACHE_TTL}s; --refresh rescans. An optional
            name... arg filters by substring.
  clone     clone a synced repo onto this machine (SSH). Offline after clone —
            the marker, rules and commands travel in the repo.
EOF
}

owner() {
  local o=""
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    o="$(gh api user --jq .login 2>/dev/null || true)"
  fi
  [[ -n "$o" ]] || o="${GITHUB_USER:-}"
  if [[ -z "$o" ]]; then
    echo "error: could not determine your GitHub username (run: roe setup / gh auth login)" >&2
    return 1
  fi
  echo "$o"
}

# repo_synced <owner> <name> — true iff the repo root carries .opencode/toolkit.
repo_synced() {
  local own="$1" name="$2"
  gh api "repos/$own/$name/contents/.opencode/toolkit" >/dev/null 2>&1
}

# scan — emits one line per repo:
#   name<TAB>private<TAB>archived<TAB>synced<TAB>description
scan() {
  local own="$1"
  gh repo list "$own" --source --limit 1000 \
    --json name,isPrivate,isArchived,description \
    --template '{{range .}}{{.name}}	{{.isPrivate}}	{{.isArchived}}	{{or .description ""}}{{"\n"}}{{end}}' \
    | while IFS=$'\t' read -r name priv arch desc; do
    [[ -z "$name" ]] && continue
    if repo_synced "$own" "$name"; then synced="yes"; else synced="no"; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$priv" "$arch" "$synced" "$desc"
  done
}

cache_fresh() {
  local own="$1" now fetched
  now="$(date +%s)"
  [[ -s "$CACHE_FILE" ]] || return 1
  fetched="$(sed -n 's/^fetched_at=//p' "$CACHE_FILE" | head -n1)"
  [[ -n "$fetched" ]] && (( now - fetched < CACHE_TTL ))
}

# cached_rows — prints the row lines from the cache (drops the meta header).
cached_rows() {
  sed -n '5,$p' "$CACHE_FILE" 2>/dev/null || true
}

refresh_cache() {
  local own="$1" err
  mkdir -p "$CACHE_DIR"
  err="$(mktemp "$CACHE_DIR/scan.err.XXXXXX")"
  if ! scan "$own" > "$CACHE_FILE.tmp.$$" 2>"$err"; then
    SCAN_ERR="$(sed -n '1p' "$err" 2>/dev/null || true)"
    rm -f "$CACHE_FILE.tmp.$$" "$err"
    return 1
  fi
  rm -f "$err"
  {
    printf '# remote_opencode_sync projects scan\n'
    printf 'owner=%s\n' "$own"
    printf 'fetched_at=%s\n' "$(date +%s)"
    printf 'name\tprivate\tarchived\tsynced\tdescription\n'
    cat "$CACHE_FILE.tmp.$$"
  } > "$CACHE_FILE"
  rm -f "$CACHE_FILE.tmp.$$"
}

list_cmd() {
  local own refresh=0
  local -a filters=()
  for a in "$@"; do
    case "$a" in
      --refresh) refresh=1 ;;
      --help|-h) usage; return 0 ;;
      -*) echo "unknown option: $a" >&2; usage; return 1 ;;
      *) filters+=("$a") ;;
    esac
  done

  own="$(owner || return 1)"

  if [[ "$refresh" -eq 1 ]] || ! cache_fresh "$own"; then
    if ! refresh_cache "$own"; then
      if [[ -s "$CACHE_FILE" ]]; then
        echo "  note: live scan failed — showing cached results" >&2
        if [[ -n "$SCAN_ERR" ]]; then echo "  gh: $SCAN_ERR" >&2; fi
      else
        echo "error: could not scan GitHub" >&2
        if [[ -n "$SCAN_ERR" ]]; then echo "  gh: $SCAN_ERR" >&2; fi
        if ! gh auth status >/dev/null 2>&1; then
          echo "  fix auth: run: roe setup" >&2
        fi
        return 1
      fi
    else
      echo "  (scanned $own — cached)" >&2
    fi
  fi

  local -a rows=()
  local line name priv arch synced desc total=0 synced_n=0
  while IFS=$'\t' read -r name priv arch synced desc; do
    [[ -z "$name" ]] && continue
    total=$((total + 1))
    [[ "$synced" == "yes" ]] && synced_n=$((synced_n + 1))
    if [[ "${#filters[@]}" -gt 0 ]]; then
      for f in "${filters[@]}"; do
        if [[ "$name" == *"$f"* ]]; then
          rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$name" "$priv" "$arch" "$synced" "$desc")")
          break
        fi
      done
    else
      rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$name" "$priv" "$arch" "$synced" "$desc")")
    fi
  done < <(cached_rows)

  echo
  echo "remote_opencode_sync projects for $own: $synced_n synced of $total"
  echo
  local first_col=""
  printf '%-40s  %-9s  %s\n' "NAME" "PRIVATE" "DESCRIPTION"
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r n p a s d <<< "$row"
    local note=""
    [[ "$a" == "true" ]] && note=" [archived]"
    printf '%-40s  %-9s  %s%s\n' "$n" "$p" "$d" "$note"
  done
  echo
  echo "  clone one:  roe clone <name>"
}

clone_cmd() {
  local name="" dir="" own
  while (($#)); do
    case "$1" in
      --dir) shift; [[ $# -gt 0 ]] || { echo "error: --dir needs a value" >&2; return 1; }; dir="$1" ;;
      --help|-h) usage; return 0 ;;
      -*) echo "unknown option: $1" >&2; usage; return 1 ;;
      *) name="$1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || { echo "error: clone needs a repo name (see: roe projects)" >&2; usage; return 1; }

  if [[ "$name" == */* ]]; then
    own="${name%/*}"
    name="${name#*/}"
  else
    own="$(owner || return 1)"
  fi
  [[ -n "$dir" ]] || dir="$name"

  echo ">> Checking $own/$name for remote_opencode_sync support..."
  if ! repo_synced "$own" "$name"; then
    echo "error: $own/$name is not a remote_opencode_sync project (no .opencode/toolkit marker)." >&2
    echo "  list synced projects:      roe projects" >&2
    echo "  adopt a local project:     roe adopt <dir>" >&2
    return 1
  fi
  echo "  compatible (.opencode/toolkit marker present)"

  if [[ -e "$dir" ]]; then
    echo "error: '$dir' already exists here" >&2
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "error: git missing (run: roe setup)" >&2
    return 1
  fi

  # GITHUB_SSH_BASE (like new-project.sh) lets tests point clone at a local fake.
  SSH_URL="${GITHUB_SSH_BASE:-git@github.com:}${own}/${name}.git"
  echo ">> Cloning $SSH_URL -> $dir..."
  if ! git clone "$SSH_URL" "$dir"; then
    echo
    echo "  Clone failed (network or SSH key missing)." >&2
    echo "  Re-run after `roe setup`, or add your SSH key to GitHub." >&2
    return 1
  fi

  if [[ ! -f "$HOME/.config/opencode/plugins/session-sync.js" ]]; then
    echo "  note: session-sync plugin not installed on this machine — run: roe setup"
  fi
  if ! git -C "$dir" config user.email >/dev/null 2>&1 || ! git -C "$dir" config user.name >/dev/null 2>&1; then
    echo "  note: no git identity set — run: roe setup"
  fi

  echo
  echo "Done. The marker, rules and commands travel in the repo — this copy is"
  echo "already synced. Next: cd $dir && opencode"
}

case "${1:-}" in
  list) shift; list_cmd "$@" ;;
  clone) shift; clone_cmd "$@" ;;
  ""|-h|--help|help) usage; exit 0 ;;
  *) echo "unknown command: $1" >&2; usage; exit 1 ;;
esac