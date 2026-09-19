#!/usr/bin/env bash
# projects.sh — list the user's GitHub repos that carry remote_opencode_sync support,
# and clone one onto this machine.
#
#   projects.sh list [--refresh] [--dir <path>] [--no-fetch] [name...]
#   projects.sh clone <name> [--dir <path>]    clone a synced project
#
# Detection: a project is "synced" iff its repo root carries the committed
# `.opencode/toolkit` marker — the exact same marker the session-sync plugin gates
# on, so this list can never disagree with what actually runs. Local copies under
# the scan root are matched to remote repos by their git origin and annotated with
# their sync state.
#
# No jq dependency: gh's --template rendering handles the JSON. No associative
# arrays either (macOS ships bash 3.2): locals are collected into a temp TSV.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CACHE_TTL="${ROE_PROJECTS_TTL:-900}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/remote_opencode_sync"
CACHE_FILE="$CACHE_DIR/projects.json"
SCAN_ERR=""
LOCALS_FILE=""

usage() {
  cat <<EOF
projects.sh — list / clone remote_opencode_sync projects

Usage:
  projects.sh list [--refresh] [name...]
  projects.sh clone <name> [--dir <path>]

  list      show your GitHub repos that carry the .opencode/toolkit marker,
            annotated with whether (and where) each exists locally under the scan
            root, and how current that copy is. Results are cached ${CACHE_TTL}s;
            --refresh rescans; an optional name... filters by substring.
            --dir <path>  scan here for local copies (default: this directory, or
                          a project's parent when run from inside a project)
            --no-fetch    don't `git fetch` local copies (faster; state may be stale)
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

# --- local project detection -------------------------------------------------

# resolve_scan_root [<dir>] — the directory whose immediate children are scanned
#   for local roe projects. Explicit <dir> wins; otherwise the current directory,
#   except when run from inside a project, where the project's parent is used (so
#   siblings are found). Echoes an absolute path.
resolve_scan_root() {
  local dir="$1" pr
  if [[ -n "$dir" ]]; then
    (cd "$dir" 2>/dev/null && pwd) || { echo "error: no such directory: $dir" >&2; return 1; }
    return 0
  fi
  if pr="$(project_root "$PWD")"; then
    dirname "$pr"
  else
    pwd
  fi
}

# local_key <dir> — the repo name a local roe project maps to: the basename of
#   its origin URL with a trailing .git stripped, else the directory name. This
#   is robust to a renamed clone dir and to ssh/https/file:// origins.
local_key() {
  local d="$1" origin base
  origin="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$origin" ]]; then
    base="${origin##*/}"
    base="${base%.git}"
    if [[ -n "$base" ]]; then echo "$base"; return 0; fi
  fi
  basename "$d"
}

# local_state <dir> <fetch> — one-line state: diverged (A ahead, B behind) /
#   behind N / ahead N / dirty N / clean / unknown (no upstream), prefixed with
#   "desynced · " on the local opt-out and suffixed "offline?" when a fetch fails.
local_state() {
  local d="$1" fetch="$2" st="" up ahead behind dirty core
  if project_desynced "$d"; then st="desynced"; fi
  if ! git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "${st:+$st · }unknown (not a git work tree)"
    return 0
  fi
  up="$(git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ -z "$up" ]]; then
    echo "${st:+$st · }unknown (no upstream)"
    return 0
  fi
  if [[ "$fetch" == "1" ]]; then
    git -C "$d" fetch origin >/dev/null 2>&1 || st="${st:+$st · }offline?"
  fi
  ahead="$(git -C "$d" rev-list --count "$up..HEAD" 2>/dev/null || echo 0)"
  behind="$(git -C "$d" rev-list --count "HEAD..$up" 2>/dev/null || echo 0)"
  dirty="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  dirty="${dirty:-0}"
  if [[ "$behind" -gt 0 && "$ahead" -gt 0 ]]; then core="diverged ($ahead ahead, $behind behind)"
  elif [[ "$behind" -gt 0 ]]; then core="behind $behind"
  elif [[ "$ahead" -gt 0 ]]; then core="ahead $ahead"
  elif [[ "$dirty" -gt 0 ]]; then core="dirty $dirty"
  else core="clean"
  fi
  echo "${st:+$st · }$core"
}

# collect_locals <root> <fetch> — writes one "key<TAB>relpath<TAB>state" line per
#   marker-bearing project found at <root> itself or in its immediate children.
collect_locals() {
  local root="$1" fetch="$2" d key rel state
  : > "$LOCALS_FILE"
  local -a cands=("$root")
  for d in "$root"/*/; do
    [[ -d "$d" ]] && cands+=("${d%/}")
  done
  for d in "${cands[@]}"; do
    project_has_marker "$d" || continue
    key="$(local_key "$d")"
    if [[ "$d" == "$root" ]]; then rel="here"; else rel="./$(basename "$d")"; fi
    state="$(local_state "$d" "$fetch")"
    printf '%s\t%s\t%s\n' "$key" "$rel" "$state" >> "$LOCALS_FILE"
  done
}

# local_of <key> — echoes "relpath<TAB>state" for the first local project matching
#   <key>, or nothing.
local_of() {
  awk -F'\t' -v k="$1" '$1 == k { print $2 "\t" $3; exit }' "$LOCALS_FILE"
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
  local own refresh=0 dir="" fetch=1
  local -a filters=()
  while (($#)); do
    case "$1" in
      --refresh) refresh=1 ;;
      --dir) shift; [[ $# -gt 0 ]] || { echo "error: --dir needs a value" >&2; return 1; }; dir="$1" ;;
      --no-fetch) fetch=0 ;;
      --help|-h) usage; return 0 ;;
      -*) echo "unknown option: $1" >&2; usage; return 1 ;;
      *) filters+=("$1") ;;
    esac
    shift
  done

  own="$(owner || return 1)"

  local remote_ok=1
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
        remote_ok=0
      fi
    else
      echo "  (scanned $own — cached)" >&2
    fi
  fi

  # --- local copies under the scan root (independent of the remote scan) ---
  local scan_root
  if ! scan_root="$(resolve_scan_root "$dir")"; then return 1; fi
  LOCALS_FILE="$(mktemp "${TMPDIR:-/tmp}/roe-locals.XXXXXX")"
  trap 'rm -f "$LOCALS_FILE"' EXIT
  if [[ "$fetch" -eq 1 ]]; then
    echo "  local projects under $scan_root (fetching each)..." >&2
  fi
  collect_locals "$scan_root" "$fetch"

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

  if [[ "$remote_ok" -eq 1 ]]; then
    echo
    echo "remote_opencode_sync projects for $own: $synced_n synced of $total"
    echo
    printf '%-38s  %-34s  %-8s  %s\n' "NAME" "LOCAL" "PRIVATE" "DESCRIPTION"
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r n p a s d <<< "$row"
      local note="" local_col="-" li=""
      [[ "$a" == "true" ]] && note=" [archived]"
      li="$(local_of "$n")"
      if [[ -n "$li" ]]; then local_col="${li%%$'\t'*} (${li#*$'\t'})"; fi
      printf '%-38s  %-34s  %-8s  %s%s\n' "$n" "$local_col" "$p" "$d" "$note"
    done
    echo
    echo "  clone one:  roe clone <name>"
  fi

  # --- local roe projects absent from the remote list (unpublished / other owner / offline) ---
  local -a extras=()
  local ekey erel estate m
  while IFS=$'\t' read -r ekey erel estate; do
    [[ -z "$ekey" ]] && continue
    if grep -Fxq "$ekey" <(cached_rows | cut -f1); then continue; fi
    if [[ "${#filters[@]}" -gt 0 ]]; then
      m=0
      for f in "${filters[@]}"; do if [[ "$ekey" == *"$f"* ]]; then m=1; fi; done
      [[ "$m" -eq 0 ]] && continue
    fi
    extras+=("$erel ($estate)")
  done < <(awk -F'\t' '!seen[$1]++ { print }' "$LOCALS_FILE")

  if [[ "${#extras[@]}" -gt 0 ]]; then
    echo
    echo "  other local roe projects under $scan_root (not in your GitHub list):"
    for e in "${extras[@]}"; do echo "    $e"; done
  fi

  [[ "$remote_ok" -eq 1 ]] || return 1
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