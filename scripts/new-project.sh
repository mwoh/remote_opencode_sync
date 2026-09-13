#!/usr/bin/env bash
# new-project.sh — create a new private GitHub repo, seed it with the cross-device
# workflow templates, and make the first commit + push.
#
# Usage:
#   new-project.sh <repo-name>
#   new-project.sh <repo-name> --setup   # auto-run setup-machine.sh if pre-flight fails
#
# Pre-flight CHECKS prerequisites but does not install them; it fails fast with a
# pointer to the checklist / setup script. Pass --setup to let it hand off automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$ROOT_DIR/templates"

usage() {
  echo "usage: new-project.sh <repo-name> [--setup]" >&2
  echo "  --setup   if prerequisites are missing, run setup-machine.sh automatically" >&2
}

NAME=""
RUN_SETUP=0
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --setup) RUN_SETUP=1; shift ;;
    -*) echo "unknown option: $1" >&2; usage; exit 1 ;;
    *) NAME="$1"; shift ;;
  esac
done

if [[ -z "$NAME" ]]; then
  usage
  exit 1
fi
if [[ ! "$NAME" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "error: repo name '$NAME' contains invalid characters" >&2
  exit 1
fi

# --- Pre-flight: check, don't install ---
PREREQ_FAIL=0
for tool in git gh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: missing prerequisite: $tool" >&2
    PREREQ_FAIL=1
  fi
done
if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
  echo "error: not authenticated with GitHub CLI (run: gh auth login)" >&2
  PREREQ_FAIL=1
fi

if [[ "$PREREQ_FAIL" -ne 0 ]]; then
  echo >&2
  echo "Some prerequisites are missing." >&2
  echo "  Checklist / guidance:  $ROOT_DIR/docs/machine-setup.md" >&2
  echo "  Lazy automated setup:  $ROOT_DIR/scripts/setup-machine.sh" >&2
  if [[ "$RUN_SETUP" -eq 1 ]]; then
    echo "Running automated setup now..." >&2
    "$ROOT_DIR/scripts/setup-machine.sh"
  else
    echo "Re-run with --setup to automate, or fix prerequisites first." >&2
    exit 1
  fi
fi

# --- Collision check ---
if gh repo view "$NAME" >/dev/null 2>&1; then
  echo "error: a GitHub repo named '$NAME' already exists" >&2
  exit 1
fi

# --- Create + clone ---
echo ">> Creating private GitHub repo '$NAME'..."
gh repo create "$NAME" --private --clone
cd "$NAME"

# --- Seed templates ---
echo ">> Seeding workflow templates..."
cp "$TEMPLATES_DIR/AGENTS.md.tpl" AGENTS.md
cp "$TEMPLATES_DIR/CONTINUE.md.tpl" CONTINUE.md
cp "$TEMPLATES_DIR/opencode.jsonc.tpl" opencode.jsonc
cp "$TEMPLATES_DIR/.gitignore.tpl" .gitignore
cp "$TEMPLATES_DIR/.env.example.tpl" .env.example
mkdir -p session-logs
touch session-logs/.gitkeep

# Portably substitute placeholders (works on both GNU and BSD sed).
subst() {
  local file="$1"
  sed "s/{{PROJECT_NAME}}/$NAME/g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}
for f in AGENTS.md CONTINUE.md; do
  subst "$f"
done

# --- First commit + push ---
echo ">> First commit + push..."
git add -A
git commit -m "chore: scaffold project with cross-device workflow templates"
git push -u origin HEAD

echo
echo "Done. Next:"
echo "  cd $NAME"
echo "  opencode"
echo "The session-sync plugin will pull and orient you automatically."