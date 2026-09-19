#!/usr/bin/env bash
# track.sh — `roe track`: see and change what a project's sync actually covers.
#
# The sync mechanism (session-sync plugin) snapshots everything git would add
# (`git add -A`), so .gitignore is the real boundary of "what syncs". track edits
# ONLY the `# --- added by remote_opencode_sync ---` block of the project's
# .gitignore — rules the user wrote themselves are never touched.
#
# Paths given on the command line are interpreted as PROJECT-ROOT-RELATIVE, then
# resolved and refused if they escape the root. The TUI always passes root-relative
# paths. One optional project directory may be given (default: current directory;
# resolved by walking up to the nearest .opencode/toolkit marker).
#
# Modes:
#   track.sh [dir]                     interactive curses TUI (python3 stdlib only;
#                                      falls back to --list when not a TTY or python3
#                                      is unavailable)
#   track.sh --list [dir]              print the three lists (pure bash, no python)
#   track.sh --ignore <path>... [--dir <dir>]    stop <path> syncing: append its pattern to the
#                                      roe block (+ `git rm --cached` if tracked)
#   track.sh --unignore <path>... [--dir <dir>]  restore <path> to the sync set: remove the
#                                      matching rule from the roe block (re-adds it)
#   (for --ignore/--unignore the project is resolved from the current directory
#    unless --dir overrides it; [dir] positional works for TUI/--list only)
#
# Exit codes:
#   0   success (or nothing to do)
#   1   not a roe project / not a usable git repo / bad input / git failure

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

GITIGNORE_BLOCK_HEADER="# --- added by remote_opencode_sync ---"

usage() {
  echo "usage:" >&2
  echo "  track.sh [dir]" >&2
  echo "  track.sh --list [dir]" >&2
  echo "  track.sh --ignore <path>... [--dir <dir>]" >&2
  echo "  track.sh --unignore <path>... [--dir <dir>]" >&2
}

# --- arg parsing ---
ACTION="tui"
TARGETS=()
DIR=""
ARGV=()
while (($#)); do
  case "$1" in
    --list) ACTION="list"; shift ;;
    --ignore) ACTION="ignore"; shift ;;
    --unignore) ACTION="unignore"; shift ;;
    --dir) shift; [[ $# -gt 0 ]] || { echo "track.sh: --dir needs a value" >&2; exit 1; }; DIR="$1"; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "track.sh: unknown option: $1" >&2; usage; exit 1 ;;
    *) ARGV+=("$1"); shift ;;
  esac
done

if [[ "$ACTION" == "ignore" || "$ACTION" == "unignore" ]]; then
  TARGETS=("${ARGV[@]}")
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "track.sh: $ACTION needs at least one <path>" >&2
    usage; exit 1
  fi
  [[ -n "$DIR" ]] || DIR="$PWD"
else
  DIR="${DIR:-${ARGV[0]:-${PWD}}}"
fi

ROOT="$(project_root "$DIR" 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "roe track — $DIR"
  echo "  not a remote_opencode_sync project (no .opencode/toolkit marker)"
  echo "  make it one with: roe adopt <dir>"
  exit 1
fi

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "roe track — $ROOT"
  echo "  not a usable git working copy — sync is impossible (re-init or clone)"
  exit 1
fi

GITIGNORE="$ROOT/.gitignore"

# --- roe-block helpers -------------------------------------------------------
# block_header_line <file> — echo the 1-based line number of the roe block header,
#   or 0 when absent.
block_header_line() {
  local n
  n="$(grep -nF "$GITIGNORE_BLOCK_HEADER" "$1" 2>/dev/null | head -n1 | cut -d: -f1 | tr -d ' ')"
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# block_ensure — make sure the block header exists in .gitignore (creating the
#   file when missing); echo its line number.
block_ensure() {
  local hdr
  hdr="$(block_header_line "$GITIGNORE")"
  if [[ "$hdr" -eq 0 ]]; then
    if [[ -s "$GITIGNORE" ]] && [[ "$(tail -c1 "$GITIGNORE" | od -An -c | tr -d ' ')" != "\n" ]]; then
      printf '\n' >> "$GITIGNORE"
    fi
    printf '\n%s\n\n' "$GITIGNORE_BLOCK_HEADER" >> "$GITIGNORE"
    hdr="$(block_header_line "$GITIGNORE")"
  fi
  echo "$hdr"
}

# remove_matching_line <pattern> — delete the roe-block line that exactly equals
#   the pattern (including variants stripped of a leading '/', or trailing '/');
#   returns 0 when a line was actually removed, 1 otherwise.
remove_matching_line() {
  local pat="$1" hdr line
  hdr="$(block_header_line "$GITIGNORE")"
  [[ "$hdr" -gt 0 ]] || return 1
  local needle
  for needle in "$pat" "${pat#/}" "${pat%/}"; do
    line="$(tail -n +"$hdr" "$GITIGNORE" | grep -nFx "$needle" | head -n1 | cut -d: -f1 | tr -d ' ')"
    if [[ "$line" =~ ^[0-9]+$ ]]; then
      sed -i "$((hdr + line - 1))d" "$GITIGNORE"
      return 0
    fi
  done
  return 1
}

# normalize_abs <path> — print the absolute path resolved against $ROOT (relative
#   inputs are project-root-relative), or nothing if it escapes the project root.
normalize_abs() {
  local p abs
  p="$1"
  [[ "$p" == /* ]] || p="$ROOT/$p"
  abs="$(realpath -m -- "$p" 2>/dev/null || true)"
  if [[ -z "$abs" || "$abs" != "$ROOT" && "$abs" != "$ROOT/"* ]]; then
    return 1
  fi
  echo "$abs"
}

# rel_pattern <abspath> — the gitignore pattern: repo-relative path, with a
#   trailing slash when it is an existing directory.
rel_pattern() {
  local rel d
  rel="${1#"$ROOT"/}"
  if d="$(realpath -m -- "$1" 2>/dev/null)" && [[ -d "$d" ]]; then
    rel="$rel/"
  fi
  [[ -n "$rel" ]] && echo "$rel"
}

# print_lists — the three pane lists to stdout (and where the TUI feeds from).
print_lists() {
  echo "Project: $(basename "$ROOT") @ $ROOT"
  echo "Tracked (committed, synced):"
  git -C "$ROOT" ls-files | sed 's/^/T\t/'
  echo "Untracked, not ignored (syncs on next wip snapshot):"
  git -C "$ROOT" status --porcelain --untracked-files=all | awk '$1=="??"{sub(/^\?\? /,"");print "U\t"$0}'
  echo "Ignored (never syncs):"
  git -C "$ROOT" status --porcelain --ignored --untracked-files=all | awk '$1=="!!"{sub(/^!! /,"");print "I\t"$0}'
}

if [[ "$ACTION" == "list" ]]; then
  print_lists
  exit 0
fi

if [[ "$ACTION" == "tui" ]]; then
  if command -v python3 >/dev/null 2>&1 && [[ -t 0 && -t 1 ]] && python3 -c "import curses" >/dev/null 2>&1; then
    exec python3 "$SCRIPT_DIR/track_tui.py" --root "$ROOT" --track-sh "$SCRIPT_DIR/track.sh"
  fi
  echo "roe track — $ROOT"
  echo "  (no interactive TUI available — python3 std. curses missing or not a terminal;"
  echo "  showing the text report instead. Use --list / --ignore / --unignore in scripts.)"
  echo
  print_lists
  exit 0
fi

# --- ignore / unignore (each <path> is root-relative) ---
fail=0
for target in "${TARGETS[@]}"; do
  abs="$(normalize_abs "$target" || true)"
  if [[ -z "$abs" ]]; then
    echo "track.sh: '$target' is outside the project root ($ROOT) — refusing" >&2
    exit 1
  fi
  pat="$(rel_pattern "$abs")"
  [[ -n "$pat" ]] || { echo "track.sh: '$target' resolves to the project root — refusing" >&2; exit 1; }

  if [[ "$ACTION" == "ignore" ]]; then
    if git -C "$ROOT" check-ignore -q -- "$abs" 2>/dev/null; then
      echo "$target: already ignored (nothing to do)"
      continue
    fi
    if git -C "$ROOT" ls-files --error-unmatch -- "$abs" >/dev/null 2>&1; then
      if ! git -C "$ROOT" rm --cached -q -- "$abs" 2>/dev/null; then
        echo "track.sh: failed to untrack '$target'" >&2
        fail=1
        continue
      fi
      echo "$target: removed from tracking (git rm --cached) — file stays on disk"
    fi
    hdr="$(block_ensure)"
    sed -i "${hdr}a\\
$pat" "$GITIGNORE"
    echo "$target: ignored (pattern '$pat' added to the roe block of .gitignore)"
  else
    if [[ ! -e "$abs" ]] && ! git -C "$ROOT" check-ignore -q -- "$abs" 2>/dev/null; then
      echo "track.sh: '$target' is not ignored in this project — nothing to do" >&2
      fail=1
      continue
    fi
    if ! remove_matching_line "$pat"; then
      if git -C "$ROOT" check-ignore -q -- "$abs" 2>/dev/null; then
        echo "track.sh: '$target' is ignored by a rule outside the roe block — not touching it" >&2
      else
        echo "track.sh: '$target' is not ignored by the roe block — nothing to do" >&2
      fi
      fail=1
      continue
    fi
    if [[ -e "$abs" ]] && ! git -C "$ROOT" ls-files --error-unmatch -- "$abs" >/dev/null 2>&1; then
      git -C "$ROOT" add -- "$abs" 2>/dev/null || true
      echo "$target: unignored and re-added (rule removed from the roe block, git add)"
    else
      echo "$target: unignored (rule removed from the roe block)"
    fi
  fi
done
exit "$fail"