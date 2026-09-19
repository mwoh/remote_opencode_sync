#!/usr/bin/env bash
# history.sh — `roe history`: per-(project × machine) archive of a project's
# opencode session conversation history, stored INSIDE the project so the normal
# sync propagates every machine's history to every machine.
#
# The conversations for this project + machine live in opencode's central db
# (~/.local/share/opencode/opencode.db). This script NEVER writes that db: it reads
# it read-only (history.py) and writes a rolling compressed archive at
# <project>/opencode-history/<host>.jsonl.gz. Restoring = reading the archive
# (list / show transcripts) — opencode has no merge-a-db-back-in API.
#
# Modes:
#   history.sh backup [dir] [--db <path>] [--host <name>]
#       archive this machine's sessions for the project (walk-up from [dir]/cwd)
#   history.sh list [dir] [--host <name>]
#       list archived sessions for this machine + project
#   history.sh show <session-id> [dir] [--host <name>]
#       render one archived session as a markdown transcript
#
# --db is only meaningful for backup (defaults to $OPENCODE_DB or
# ~/.local/share/opencode/opencode.db). --host defaults to the short hostname.
# One optional project directory may be given (default: current directory; resolved
# by walking up to the nearest .opencode/toolkit marker).
#
# Exit codes: 0 ok; 1 not a roe project / db missing / archive missing / not found.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PY="$SCRIPT_DIR/history.py"

usage() {
  echo "usage:" >&2
  echo "  history.sh backup [dir] [--db <path>] [--host <name>]" >&2
  echo "  history.sh list   [dir] [--host <name>]" >&2
  echo "  history.sh show <session-id> [dir] [--host <name>]" >&2
}

SUB="${1:-}"
[[ -n "$SUB" ]] || { usage; exit 1; }
shift

case "$SUB" in
  backup|list) ;;
  show) ;;
  --help|-h) usage; exit 0 ;;
  *) echo "history.sh: unknown subcommand: $SUB" >&2; usage; exit 1 ;;
esac

DIR=""
DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
HOST="$(hostname -s 2>/dev/null || hostname)"
SESSION_ID=""
ARGS=()
while (($#)); do
  case "$1" in
    --db) shift; [[ $# -gt 0 ]] || { echo "history.sh: --db needs a value" >&2; exit 1; }; DB="$1"; shift ;;
    --host) shift; [[ $# -gt 0 ]] || { echo "history.sh: --host needs a value" >&2; exit 1; }; HOST="$1"; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "history.sh: unknown option: $1" >&2; usage; exit 1 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ "$SUB" == "show" ]]; then
  SESSION_ID="${ARGS[0]:-}"
  [[ -n "$SESSION_ID" ]] || { echo "history.sh: show needs a <session-id>" >&2; usage; exit 1; }
  DIR="${ARGS[1]:-${PWD}}"
else
  DIR="${ARGS[0]:-${PWD}}"
fi

ROOT="$(project_root "$DIR" 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "roe history — $DIR"
  echo "  not a remote_opencode_sync project (no .opencode/toolkit marker)"
  echo "  make it one with: roe adopt <dir>"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "roe history: needs python3 (standard library) — not found on this machine" >&2
  exit 1
fi

if [[ "$SUB" == "backup" ]]; then
  python3 "$PY" backup --root "$ROOT" --host "$HOST" --db "$DB"
  rc=$?
  # Safety: an archive is the FULL raw transcript. If this project ignores it (e.g. a
  # public repo), say so plainly rather than letting the user believe it will sync.
  if [[ $rc -eq 0 ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$ROOT" check-ignore -q -- "opencode-history/$HOST.jsonl.gz" 2>/dev/null; then
      echo "note: opencode-history/ is gitignored in this repo — this archive stays local and will NOT sync."
      echo "      (archives are full transcripts; keep a project private to sync them)"
    fi
  fi
  exit "$rc"
elif [[ "$SUB" == "list" ]]; then
  exec python3 "$PY" list --root "$ROOT" --host "$HOST"
else
  exec python3 "$PY" show --root "$ROOT" --host "$HOST" --session "$SESSION_ID"
fi