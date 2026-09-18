#!/usr/bin/env bash
# new-project.sh — create a new private GitHub repo for a cross-device project.
#
# Modes:
#   new-project.sh <repo-name> [--setup]          create from scratch (empty repo)
#   new-project.sh --existing <dir> [options]     turn an existing directory into a repo
#
# Options:
#   --model <id>      opencode model id to pin in the project's opencode.jsonc, so
#                     every machine runs the same model (default: $MODEL_PIN, else
#                     the model from your global opencode config, else a prompt).
#                     When adopting, an existing model in the config is respected.
#   --setup            if prerequisites are missing, run setup-machine.sh automatically
#   --existing <dir>   adopt an existing directory (must precede other options)
#   --name <repo>      GitHub repo name (default: basename of the directory)
#   --scan | --no-scan orient the first session: scan the codebase and fill the
#                      AGENTS.md Project overview / CONTINUE.md Status. Default: --scan.
#   --resolve <mode>   how to handle files that already exist (AGENTS.md, .gitignore, etc.):
#                      append (default) | ask | skip | overwrite
#   --force            allow replacing an existing git origin with the new repo's remote
#
# Pre-flight CHECKS prerequisites but does not install them; fails fast with guidance.
# Never overwrites existing user files without asking (see --resolve).
#
# Re-runs are safe: if create/seed/commit/push is interrupted (network drop, timeout,
# ...), re-running the same command resumes where it left off instead of failing:
#   - a scratch dir that is already a clone of the target URL, or an empty repo that
#     never got seeded, count as resumable;
#   - anything else (a genuine collision) is refused with a hint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$ROOT_DIR/templates"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

MARKER="remote_opencode_sync"

usage() {
  echo "usage:" >&2
  echo "  new-project.sh <repo-name> [--setup] [--model <id>]" >&2
  echo "  new-project.sh --existing <dir> [--name <repo>] [--scan|--no-scan] [--resolve append|ask|skip|overwrite] [--force] [--setup] [--model <id>]" >&2
}

# ---- arg parsing ----
NAME=""
MODE="scratch"
EXISTING_DIR=""
RESOLVE="append"
SCAN=1
FORCE=0
RUN_SETUP=0
MODEL_FLAG=""

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --setup) RUN_SETUP=1; shift ;;
    --model) shift; [[ $# -gt 0 ]] || { echo "error: --model needs a value" >&2; exit 1; }; MODEL_FLAG="$1"; shift ;;
    --existing) MODE="existing"; shift; [[ $# -gt 0 ]] || { echo "error: --existing needs a directory" >&2; exit 1; }; EXISTING_DIR="$1"; shift ;;
    --name) shift; [[ $# -gt 0 ]] || { echo "error: --name needs a value" >&2; exit 1; }; NAME="$1"; shift ;;
    --scan) SCAN=1; shift ;;
    --no-scan) SCAN=0; shift ;;
    --resolve) shift; [[ $# -gt 0 ]] || { echo "error: --resolve needs a mode" >&2; exit 1; }; RESOLVE="$1"; shift ;;
    --force) FORCE=1; shift ;;
    -*) echo "unknown option: $1" >&2; usage; exit 1 ;;
    *) NAME="$1"; shift ;;
  esac
done

[[ "$RESOLVE" =~ ^(append|ask|skip|overwrite)$ ]] || { echo "error: --resolve must be append|ask|skip|overwrite" >&2; exit 1; }

# ---- pre-flight: check, don't install ----
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
  echo "  Lazy automated setup:  roe setup ($ROOT_DIR/scripts/setup-machine.sh)" >&2
  if [[ "$RUN_SETUP" -eq 1 ]]; then
    echo "Running automated setup now..." >&2
    "$ROOT_DIR/scripts/setup-machine.sh"
  else
    echo "Re-run with --setup to automate, or fix prerequisites first." >&2
    exit 1
  fi
fi

PROJECT_DIR=""
IS_REPO=1
HAS_COMMITS=1
EXISTING_ORIGIN=""

if [[ "$MODE" == "existing" ]]; then
  # ---- validate the existing directory and inspect its git state ----
  if [[ ! -d "$EXISTING_DIR" ]]; then
    echo "error: --existing directory '$EXISTING_DIR' does not exist" >&2
    exit 1
  fi
  PROJECT_DIR="$(cd "$EXISTING_DIR" && pwd)"
  [[ -n "$NAME" ]] || NAME="$(basename "$PROJECT_DIR")"

  set +e
  git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; IS_REPO=$?
  git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; HAS_COMMITS=$?
  set -e
  # NOTE: HAS_COMMITS == 0  ⇔  repo already has commits

  if [[ "$IS_REPO" -ne 0 ]]; then
    echo ">> Not a git repo — initializing at $PROJECT_DIR..."
    git -C "$PROJECT_DIR" init -b main
  fi

  EXISTING_ORIGIN="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"

  # safety: warn about unignored heavy dirs
  HEAVY_DIRS=(node_modules .venv venv dist build target __pycache__)
  for d in "${HEAVY_DIRS[@]}"; do
    if [[ -d "$PROJECT_DIR/$d" ]]; then
      echo "  warning: '$d' exists — it will be pushed unless a .gitignore excludes it (check below)."
    fi
  done
else
  # ---- scratch mode: the directory will be created by gh repo create --clone
  [[ -n "$NAME" ]] || { usage; exit 1; }
  PROJECT_DIR="$(pwd)/$NAME"
  IS_REPO=1
  HAS_COMMITS=1
  EXISTING_ORIGIN=""
fi

if [[ ! "$NAME" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "error: repo name '$NAME' contains invalid characters" >&2
  exit 1
fi

# ---- resolve owner + target URLs ----
OWNER=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  OWNER="$(gh api user --jq .login 2>/dev/null || true)"
fi
[[ -n "$OWNER" ]] || OWNER="${GITHUB_USER:-}"
if [[ -z "$OWNER" ]]; then
  echo "error: could not determine your GitHub username (run: roe setup / gh auth login)" >&2
  exit 1
fi
# GITHUB_SSH_BASE lets tests point the origin URL at a local fake. It is
# prepended verbatim to "${OWNER}/${NAME}.git", so it must include the URL
# separator: e.g. "file:///tmp/fake/" or the default "git@github.com:".
SSH_BASE="${GITHUB_SSH_BASE:-git@github.com:}"
SSH_URL="${SSH_BASE}${OWNER}/${NAME}.git"
REPO_URL="https://github.com/$OWNER/$NAME"

# ---- resume detection + collision check ----
# Re-running the same command after an interruption (network drop, timeout, ...)
# continues the previous attempt instead of failing: a scratch dir that is a clone
# of the target URL, or an empty repo we created that never got its seed pushed,
# both count as "resume". Anything else is a genuine collision and we refuse to
# touch it.
RESUME=0
REPO_EXISTS=0
if gh repo view "$NAME" >/dev/null 2>&1; then REPO_EXISTS=1; fi

remote_empty() {
  local out
  out="$(git ls-remote "$SSH_URL" 'refs/heads/*' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$out" == "0" ]]
}

if [[ "$MODE" == "scratch" ]]; then
  if [[ -d "$PROJECT_DIR" ]]; then
    local_origin="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$local_origin" && "$local_origin" == "$SSH_URL" ]]; then
      RESUME=1
    else
      echo "error: directory '$NAME' already exists and is not a previous clone of $REPO_URL" >&2
      exit 1
    fi
  elif [[ "$REPO_EXISTS" -eq 1 ]]; then
    if remote_empty; then
      RESUME=1
    else
      echo "error: a GitHub repo named '$NAME' already exists and is not an empty stub (genuine collision)." >&2
      echo "  Pick a different name, or delete it and re-run: gh repo delete $NAME --yes" >&2
      exit 1
    fi
  fi
else
  if [[ -n "$EXISTING_ORIGIN" && "$EXISTING_ORIGIN" != "$SSH_URL" && "$FORCE" -eq 0 ]]; then
    echo "error: origin is already '$EXISTING_ORIGIN'." >&2
    echo "  This script would replace it with $REPO_URL." >&2
    echo "  Re-run with --force to repoint origin, or handle the existing remote yourself." >&2
    exit 1
  fi
fi

# ---- resolve which model to pin in the project config ----
# On a resume the workflow files already exist, so never re-prompt for a model.
if [[ "$RESUME" -eq 1 ]] && [[ -f "$PROJECT_DIR/opencode.json" || -f "$PROJECT_DIR/opencode.jsonc" ]]; then
  MODEL=""
else
  MODEL="$(model_resolve "$MODEL_FLAG" || true)"
fi

# ---- seeding helpers + conflict resolution ----
subst() {
  local file="$1"
  sed "s/{{PROJECT_NAME}}/$NAME/g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  if grep -qF "@@MODEL@@" "$file"; then
    if [[ -n "$MODEL" ]]; then
      sed "s|@@MODEL@@|$MODEL|g" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
      grep -vF "@@MODEL@@" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    fi
  fi
}

TO_DO=()

resolve_prompt() {
  # interactive resolution for files where appending makes sense.
  # usage: resolve_prompt <label> <template>
  local label="$1" tpl="$2"
  while true; do
    read -r -p "  '$label' exists — [s]kip / [a]ppend / [o]verwrite / [v]iew template: " ans
    case "$ans" in
      s|skip) echo "skip"; return ;;
      a|append) echo "append"; return ;;
      o|overwrite) echo "overwrite"; return ;;
      v|view) sed -n '1,60p' "$tpl"; continue ;;
      *) ;;
    esac
  done
}

resolve_noappend() {
  # interactive resolution for files where appending makes no sense.
  local label="$1" tpl="$2"
  while true; do
    read -r -p "  '$label' exists — [s]kip / [o]verwrite / [v]iew template: " ans
    case "$ans" in
      s|skip) echo "skip"; return ;;
      o|overwrite) echo "overwrite"; return ;;
      v|view) sed -n '1,60p' "$tpl"; continue ;;
      *) ;;
    esac
  done
}

already_marked() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  if grep -qF "$MARKER" "$file"; then
    return 0
  fi
  # an existing sync-rules block in AGENTS.md also counts as sync content, so a
  # resume of a previous scaffold does not append a duplicate copy of the rules.
  [[ "$(basename "$file")" == "AGENTS.md" ]] && grep -qE '^## 1\. Session start' "$file"
}

# seed <template>   (target filename = template basename minus .tpl)
seed() {
  local tpl="$1"
  local target; target="$(basename "$tpl")"
  [[ "$target" == *.tpl ]] && target="${target%.tpl}"
  local file="$PROJECT_DIR/$target"

  if [[ ! -f "$file" ]]; then
    cp "$tpl" "$file"
    subst "$file"
    echo "  created $target"
    return
  fi

  local choice
  case "$RESOLVE" in
    skip) choice="skip" ;;
    overwrite) choice="overwrite" ;;
    ask)
      case "$target" in
        AGENTS.md|.gitignore) choice="$(resolve_prompt "$target" "$tpl")" ;;
        *) choice="$(resolve_noappend "$target" "$tpl")" ;;
      esac
      ;;
    append)
      case "$target" in
        AGENTS.md|.gitignore) choice="append" ;;
        *) choice="skip" ;;
      esac
      ;;
  esac

  case "$choice" in
    append)
      if already_marked "$file"; then
        echo "  skipped $target (already contains sync content)"
        return
      fi
      if [[ "$target" == "AGENTS.md" ]]; then
        printf '\n\n' >> "$file"
        cat "$TEMPLATES_DIR/workflow-rules.md.tpl" >> "$file"
      else
        printf '\n' >> "$file"
        cat "$TEMPLATES_DIR/.gitignore.append.tpl" >> "$file"
      fi
      echo "  appended sync content to $target"
      TO_DO+=("Review the appended sync content in $target (keep what you want)")
      ;;
    overwrite)
      cp "$tpl" "$file"
      subst "$file"
      echo "  overwrote $target"
      TO_DO+=("Replaced $target with the workflow template — confirm no content was lost")
      ;;
    skip)
      echo "  skipped $target (already exists)"
      TO_DO+=("$target already existed and was not touched — merge the workflow files manually if needed")
      ;;
  esac
}

# ---- [1/4] ensure the GitHub repo + working directory exist ----
echo ">> [1/4] GitHub repo: $REPO_URL"

if [[ "$MODE" == "existing" ]]; then
  if [[ "$REPO_EXISTS" -eq 1 ]]; then
    echo "  repo already exists (resume path) — skipping create"
  else
    gh repo create "$NAME" --private >/dev/null
    echo "  created private repo"
  fi
  if [[ -n "$EXISTING_ORIGIN" ]]; then
    if [[ "$EXISTING_ORIGIN" != "$SSH_URL" ]]; then
      git -C "$PROJECT_DIR" remote set-url origin "$SSH_URL"
      echo ">> Repointed origin -> $SSH_URL"
    fi
  else
    git -C "$PROJECT_DIR" remote add origin "$SSH_URL"
    echo ">> Set origin -> $SSH_URL"
  fi
  cd "$PROJECT_DIR"
else
  if [[ "$RESUME" -eq 1 ]]; then
    if [[ -d "$PROJECT_DIR" ]]; then
      echo "  resuming previous clone at $PROJECT_DIR (origin -> $SSH_URL)"
    else
      echo "  repo exists as an empty stub — cloning it..."
      git clone "$SSH_URL" "$NAME"
    fi
  elif [[ "$REPO_EXISTS" -eq 1 ]]; then
    echo "  repo exists as an empty stub (never seeded) — cloning it..."
    git clone "$SSH_URL" "$NAME"
  else
    echo "  creating + cloning private repo..."
    if ! gh repo create "$NAME" --private --clone 2>/dev/null; then
      # raced: the repo appeared between the existence check and create
      if gh repo view "$NAME" >/dev/null 2>&1 && remote_empty; then
        echo "  repo appeared mid-run — cloning the empty stub..."
        git clone "$SSH_URL" "$NAME"
      else
        echo "error: could not create repo '$NAME'" >&2
        exit 1
      fi
    fi
  fi
  # normalize origin to the canonical target URL (also makes resume detection exact)
  git -C "$PROJECT_DIR" remote set-url origin "$SSH_URL" 2>/dev/null || true
  cd "$PROJECT_DIR"
fi

# ---- [2/4] seed the standard files ----
cd "$PROJECT_DIR"
echo ">> [2/4] Seeding workflow files (resolve=$RESOLVE)..."
seed "$TEMPLATES_DIR/AGENTS.md.tpl"
seed "$TEMPLATES_DIR/CONTINUE.md.tpl"
seed "$TEMPLATES_DIR/opencode.jsonc.tpl"
seed "$TEMPLATES_DIR/.gitignore.tpl"
seed "$TEMPLATES_DIR/.env.example.tpl"
mkdir -p session-logs
[[ -f session-logs/.gitkeep ]] || touch session-logs/.gitkeep
mkdir -p .opencode
printf 'remote_opencode_sync\n' > .opencode/toolkit

# ---- model pin (adopt mode): respect an existing model, else pin the resolved one ----
if [[ "$MODE" == "existing" ]]; then
  existing_model="$(model_get "$PROJECT_DIR" || true)"
  if [[ -n "$existing_model" ]]; then
    echo "  kept existing config model: $existing_model"
  elif [[ "$RESOLVE" == "skip" ]]; then
    echo "  (existing config not touched — --resolve skip; pin one later with: roe model <id>)"
  elif [[ -n "$MODEL" ]]; then
    pin_file="$(model_set "$PROJECT_DIR" "$MODEL")"
    echo "  pinned model $MODEL in $(basename "$pin_file")"
  fi
fi

# ---- FIRST STEP orientation (existing-dir mode only) ----
if [[ "$MODE" == "existing" && "$SCAN" -eq 1 && ! "$(grep -cF '## FIRST STEP' "CONTINUE.md" 2>/dev/null || true)" -gt 0 ]]; then
  printf '\n\n## FIRST STEP\n' >> "CONTINUE.md"
  cat >> "CONTINUE.md" <<'EOF'
_(from remote_opencode_sync — this project was just adopted from an existing directory.)_
Orient yourself before other work: scan the codebase (structure, entry points, key
modules, build/test commands, and any existing docs). Fill in the `## Project overview`
section of `AGENTS.md` and the `Status` section of this file based on what you find,
then propose the next 1–3 steps and add them to NEXT STEPS.
EOF
fi
if [[ "$MODE" == "existing" && "$SCAN" -eq 0 && ! "$(grep -cF '## FIRST STEP' "CONTINUE.md" 2>/dev/null || true)" -gt 0 ]]; then
  printf '\n\n## FIRST STEP\n' >> "CONTINUE.md"
  cat >> "CONTINUE.md" <<'EOF'
_(from remote_opencode_sync — this project was just adopted from an existing directory.)_
Ask the user to describe this project's background and current state, then fill in the
`## Project overview` section of `AGENTS.md` and the `Status` section of this file
together, and agree on the first next steps.
EOF
fi

# ---- [3/4] commit, [4/4] push ----
if ! git config user.email >/dev/null 2>&1 || ! git config user.name >/dev/null 2>&1; then
  echo "error: git user identity is not set." >&2
  echo "  run:  git config --global user.name \"Your Name\"" >&2
  echo "        git config --global user.email \"you@example.com\"" >&2
  echo "  (or run roe setup / scripts/setup-machine.sh, which sets it from your GitHub profile)" >&2
  exit 1
fi
echo ">> [3/4] Committing..."
if [[ -z "$(git status --porcelain 2>/dev/null || true)" ]]; then
  echo "  nothing new to commit (resume of an earlier run)"
else
  git add -A
  if [[ "$MODE" == "existing" ]]; then
    if [[ "$HAS_COMMITS" -eq 0 ]]; then
      git commit -m "chore: adopt cross-device workflow templates"
    else
      git commit -m "feat: import existing project and add cross-device workflow templates"
    fi
  else
    git commit -m "chore: scaffold project with cross-device workflow templates"
  fi
fi
echo ">> [4/4] Pushing..."
if ! git push -u origin HEAD; then
  echo
  echo "  Push failed (network hiccup?). Everything is committed locally." >&2
  echo "  Re-run the same command to resume — it skips create/seed/commit and only pushes left." >&2
  exit 1
fi

echo
echo "Done."
if [[ "$MODE" == "existing" ]]; then
  echo "  Adopted: $PROJECT_DIR -> $REPO_URL (existing history preserved)"
else
  echo "  Created: $PROJECT_DIR -> $REPO_URL"
fi
if [[ ${#TO_DO[@]} -gt 0 ]]; then
  echo
  echo "  Things to review:"
  for item in "${TO_DO[@]}"; do
    echo "    - $item"
  done
fi
echo
echo "  Next: cd $PROJECT_DIR && opencode"
[[ "$MODE" == "existing" ]] && echo "  (restart opencode if it was already open here)" || true