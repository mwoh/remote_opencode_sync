# Scripts Reference

The engine room of remote_opencode_sync. Every one-off job a human does — install,
setup, create, adopt, clone, desync, uninstall — is a plain bash script under
`scripts/`, and the whole thing is wired to the `roe` front-end.

Read `PLAN.md` for the architecture and `docs/daily-workflow.md` for the everyday
playbook. This page is the "what exactly does each script do and what can I hand it".

## Where things live

On any set-up machine the toolkit is a git clone at
`~/.local/share/remote_opencode_sync/`, so every script is at
`~/.local/share/remote_opencode_sync/scripts/`. You can call a script directly by that
path, or — the normal way — through the `roe` command:

```
roe <command> [args...]
```

`roe` itself is a symlink at `~/.local/bin/roe` -> the toolkit's `bin/roe`. Because it
resolves itself with `readlink -f`, it always runs the copy of the scripts it came from,
even after you clone the repo elsewhere. `roe update` keeps that copy current.

## At a glance

| Script                     | `roe` command              | Job |
|----------------------------|----------------------------|-----|
| `bootstrap.sh`             | — (install one-liner only) | install / update the whole toolkit |
| `update.sh`                | `roe update`               | update an installed toolkit |
| `setup-machine.sh`         | `roe setup` (alias `machine`) | one-time machine setup |
| `new-project.sh`           | `roe new <name>`, `roe create <name>`, `roe adopt <dir>` | create or adopt a synced project (resumable) |
| `projects.sh`              | `roe projects` (alias `list`), `roe clone <name>` | discover & clone synced projects |
| `desync.sh`                | `roe desync`               | freeze one working copy out of sync |
| `resync.sh`                | `roe resync`               | undo a desync |
| `uninstall.sh`             | `roe uninstall`            | remove the toolkit + what setup created |
| `lib.sh`                   | (sourced, not executable)  | shared helpers |

## How `roe` dispatches — and hands options through

`bin/roe` never re-implements a script. It `exec`s the script (the same process
replaces itself), passing **every argument after the command name straight to the
script**:

```bash
# bin/roe (relevant lines)
new|create)  require "$SC_NEW"          && exec "$SC_NEW"        "$@" ;;
adopt)       require "$SC_NEW"          && exec "$SC_NEW" --existing "$@" ;;
projects|list) require "$SC_PROJECTS"   && exec "$SC_PROJECTS" list "$@" ;;
clone)       require "$SC_PROJECTS"     && exec "$SC_PROJECTS" clone "$@" ;;
setup|machine) require "$SC_SETUP"      && exec "$SC_SETUP"      "$@" ;;
update)      require "$SC_UPDATE"       && exec "$SC_UPDATE"     "$@" ;;
uninstall)   require "$SC_UNINSTALL"    && exec "$SC_UNINSTALL"  "$@" ;;
```

There are only three shapes of argument handling to keep in mind:

1. **Complete pass-through** — `roe new`, `roe setup`, `roe update`, `roe desync`,
   `roe resync`, `roe uninstall` forward `"$@"` unchanged. Anything the script accepts,
   `roe` accepts identically, including `--help`.

2. **A fixed prefix injected by `roe`** — three commands prepend a word before
   forwarding your args:
   - `roe adopt <dir> ...`  →  `new-project.sh --existing <dir> ...`
   - `roe projects ...`     →  `projects.sh list ...`
   - `roe clone ...`        →  `projects.sh clone ...`

   Your own flags still come through in order afterwards, so these all work:

   ```
   roe adopt . --name legacy --resolve ask --no-scan --force
   roe projects --refresh docs
   roe clone side-quest --dir ../side-quest
   ```

3. **Inline commands with no script** — `roe version` (prints `git describe`), `roe
   help`, and `roe model [id]`. `roe model` reads/edits the project's `opencode.json(c)`
   directly via `lib.sh` helpers; there is no `model.sh`. `roe help` prints `roe`'s own
   usage.

Because the scripts are `exec`'d (not sub-shelled), their stdout, stderr, and exit code
are the ones you see: `roe` adds nothing and swallows nothing.

Aliases: `roe create` = `roe new`, `roe list` = `roe projects`.

---

## `bootstrap.sh` — install / reinstall entry point

```
curl -fsSL https://raw.githubusercontent.com/mwoh/remote_opencode_sync/main/scripts/bootstrap.sh | bash
```

- Ensures `curl` and `git` (installs `git` via the detected package manager if missing).
- Clones the toolkit to `~/.local/share/remote_opencode_sync`; if already cloned, does a
  `git pull --ff-only` (this is the canonical update path).
- Runs `scripts/setup-machine.sh`.
- Substitutes your real GitHub handle into the `@@GITHUB_USER@@` placeholders in the
  local copy's README/docs.

Options / env:

| Input | Effect |
|-------|--------|
| `OC_SYNC_DIR` | override the install directory |
| `GITHUB_USER` | fed to `relink_placeholders` when no `gh` login |

`roe update` is the polite descendant of this script (guarded to the official origin,
no re-clone).

## `setup-machine.sh` — one-time machine setup

```
roe setup                # or: scripts/setup-machine.sh
```

The "lazy" setup companion to `docs/machine-setup.md`. No options, no arguments —
idempotent, safe to re-run. Does, in order:

1. Checks/installs prerequisites: `git`, `gh`, `node` (via the detected package manager).
2. Installs `opencode` (npm, then the official script fallback).
3. `gh auth login` if not already authenticated.
4. Generates `~/.ssh/id_ed25519` and registers it with GitHub (title `<hostname>-opencode`).
5. Sets a global git identity from the GitHub profile, if missing.
6. Installs the **global** session-sync plugin to
   `~/.config/opencode/plugins/session-sync.js`.
7. Symlinks `~/.local/bin/roe` -> the toolkit's `bin/roe`, and adds
   `~/.local/bin` to `PATH` in `~/.bashrc` if absent.
8. Writes the uninstall manifest (see `uninstall.sh`) recording exactly what it created
   and what pre-existed.

Env: `UNINSTALL_STATE_DIR`, `UNINSTALL_MANIFEST` (see below).

## `update.sh` — update an installed toolkit

```
roe update               # or: ~/.local/share/remote_opencode_sync/scripts/update.sh
```

- Refuses to run if `origin` is not the official
  `github.com/mwoh/remote_opencode_sync.git`.
- Discards placeholder edits, `pull --ff-only`, re-runs `setup-machine.sh` (refreshes
  the global plugin), re-links placeholders.

No options. Close opencode and restart it afterward to load the refreshed plugin.

## `new-project.sh` — create / adopt a synced project

The biggest script. Two modes; both resumable.

```
scripts/new-project.sh <repo-name> [--setup] [--model <id>]
scripts/new-project.sh --existing <dir> [--name <repo>] [--scan|--no-scan]
                       [--resolve append|ask|skip|overwrite] [--force]
                       [--setup] [--model <id>]
```

| Option | Applies to | Effect |
|--------|-----------|--------|
| `<repo-name>` | scratch | name of the new repo + target directory (also the GitHub repo name) |
| `--existing <dir>` | adopt | turn an existing local directory into a synced repo |
| `--name <repo>` | adopt | GitHub repo name (default: basename of `<dir>`) |
| `--model <id>` | both | opencode model id to pin in `opencode.jsonc` |
| `--setup` | both | run `setup-machine.sh` automatically if prerequisites are missing |
| `--scan` / `--no-scan` | adopt | orient the first session — scan the codebase and fill `AGENTS.md` overview + `CONTINUE.md` status (default: `--scan`) |
| `--resolve <mode>` | adopt | how to handle files that already exist (`AGENTS.md`, `.gitignore`, …): `append` (default) \| `ask` \| `skip` \| `overwrite` |
| `--force` | adopt | allow replacing an existing git origin with the new repo's remote |
| `--help` | both | usage |

What it does (both modes):

1. **[1/4]** Resolve owner + target URLs, run the resume/collision check, create the
   private GitHub repo (or reuse a leftover empty stub) and get into the working copy;
   normalizes `origin` to the canonical SSH URL. Replacing a foreign `origin` (with
   `--force`) prints what the previous origin was.
2. **[2/4]** Seed the workflow files from `templates/`: `AGENTS.md`, `CONTINUE.md`,
   `opencode.jsonc` (incl. session commands + pinned model), `.gitignore`, `.env.example`,
   plus the `.opencode/toolkit` marker — the exact marker the session-sync plugin gates
   on. Never overwrites existing user files without asking (`--resolve`). Existing-mode
   snapshots the pre-seed tree: any pre-existing uncommitted changes are called out before
   the commit (they are included in it — warn-and-continue).
3. **[3/4]** Commit (`chore: scaffold …` for scratch, `chore: adopt …` / `feat: import
   …` for adopt) — skipped if there is nothing new.
4. **[4/4]** `git push -u origin HEAD --follow-tags` (annotated tags reachable from the
   pushed history travel too). If the push fails, everything committed is kept
   and **re-running the same command resumes**: it detects a leftover clone of the target
   URL or an empty repo stub, skips create/seed/commit, re-prompts for nothing, and only
   finishes the push. A genuine collision (non-empty repo that isn't yours) is refused
   with a hint (`gh repo delete <name> --yes`). After a successful push, if the pushed
   branch differs from the remote's default branch (e.g. `master` pushed into a fresh
   repo defaulting to `main`) a note tells you to align them.

Model resolution precedence: `--model <id>` → `$MODEL_PIN` → your global opencode config
model → interactive prompt (adopt additionally respects an existing model in the config).

Env: `MODEL_PIN`, `GITHUB_USER` (owner fallback), `GITHUB_SSH_BASE` (see below).

## `projects.sh` — discover & clone synced projects

```
scripts/projects.sh list [--refresh] [name...]
scripts/projects.sh clone <name|owner/name> [--dir <path>]
```

A project counts as "synced" iff its repo root carries the committed `.opencode/toolkit`
marker — the same marker the plugin gates on, so the list can never disagree with what
actually runs. Marker probing uses `gh api`; no `jq` needed (`gh` `--template` renders
the JSON).

### `list`
- Scans up to 1000 of your own source repos, caching results to
  `$XDG_CACHE_HOME/remote_opencode_sync/projects.json` (default
  `~/.cache/remote_opencode_sync/projects.json`, TTL 900s) with a header of
  `owner=`, `fetched_at=`, then tab-separated rows.
- `--refresh` forces a rescan. An optional `name...` filters by substring.
- Offline fallback: if a live scan fails but a cache exists, it shows the cached rows
  with a note; with no cache at all it errors (`roe setup` to fix auth).

### `clone`
- Verifies the `owner/name` carries the marker before touching anything.
- `owner/name` form clones a repo owned by someone else; a bare `<name>` resolves to
  your own account.
- `--dir <path>` overrides the target directory (default: the repo name).
- Refuses if the target path already exists. Reminds you if the SSH key / plugin /
  git identity are missing (`roe setup`).
- Offline-to-sync: the marker, rules, and commands all travel in the repo, so a fresh
  clone is instantly a full participant.

Env: `ROE_PROJECTS_TTL` (cache TTL seconds), `XDG_CACHE_HOME`, `GITHUB_USER`,
`GITHUB_SSH_BASE`.

## `desync.sh` — opt one machine's copy out of sync

```
roe desync [-y]          # run inside the project directory
```

Guards: must be inside a git work tree **and** carry the `.opencode/toolkit` marker.
Already-desynced copies are detected and reported (`roe resync` to undo).

Does, both strictly local and reversible:

1. Writes `.opencode/state/no-session-sync` (gitignored) — the global plugin becomes a
   no-op in this working copy. If `.opencode/state/` isn't ignored yet, it appends the
   ignore rule to the *local* `.gitignore`, pinned with
   `git update-index --skip-worktree` so it can never be committed/pushed.
2. Strips the sync-rules block from the local `AGENTS.md` (keeping the header + Project
   overview) and pins that edit with `--skip-worktree` too.

The committed sync files stay as they are in the repo (`AGENTS.md`, `opencode.jsonc`,
`CONTINUE.md`, the marker, …) — other machines keep using them; this copy is simply
frozen out. Desync never commits or pushes, and warns if the tree was already dirty.

| Option | Effect |
|--------|--------|
| `-y`, `--yes` | skip the interactive confirmation |
| `-h`, `--help` | usage |

## `resync.sh` — undo a desync

```
roe resync               # run inside the project directory
```

- Removes `.opencode/state/no-session-sync`.
- If `AGENTS.md` (or `.gitignore`) carries a local `skip-worktree` pin, un-pins and
  restores both files from the repo (`git checkout -- …`).
- No-op (exit 0) if the copy was never desynced.

No options.

## `uninstall.sh` — reverse the install

```
roe uninstall [options]  # or: scripts/uninstall.sh
```

Reads the manifest at `~/.local/state/remote_opencode_sync/uninstall.conf` (written by
setup-machine.sh) and removes **only** what the install created — anything you already
had is left alone. Project files are never touched. Without the manifest it degrades to
removing just the toolkit clone + plugin (and warns).

| Option | Effect |
|--------|--------|
| `--yes` | take the recommended defaults, no prompts: remove toolkit + plugin + git identity setup; **keep** tools, `gh` login, and the SSH key |
| `--dry-run` | print exactly what would be removed; change nothing |
| `--no-tools` | never touch tool packages (`git`/`gh`/`node`/`opencode`) |
| `--no-auth` | never log out of `gh` |
| `--no-ssh-key` | never touch the SSH key |
| `--no-identity` | never touch the git identity |
| `--no-plugin` | keep the session-sync plugin |
| `--no-clone` | keep the toolkit clone |
| `--conf <file>` | use a different manifest path |
| `-h`, `--help` | usage |

Removal order is dependency-sorted (plugin → identity → SSH → `gh` logout → opencode →
tool packages → `roe` symlink + PATH line → toolkit clone → manifest). The clone guard
refuses to `rm -rf` anything outside `$HOME` or anything that doesn't look like the
toolkit.

Env: `UNINSTALL_STATE_DIR`, `UNINSTALL_MANIFEST`.

## `lib.sh` — shared helpers (not executable)

Sourced by every script (`source "$SCRIPT_DIR/lib.sh"`). Plain bash, no `jq`/`python`
dependencies. Notable functions:

| Helper | What it does |
|--------|--------------|
| `relink_placeholders <root> [gh_user]` | replaces `@@GITHUB_USER@@` in `*.md` files under `<root>` |
| `detect_installer` | echoes `apt-get` / `brew` / `dnf` / `pacman` (else empty) |
| `pkg_install` / `pkg_remove` | install/remove a package via the detected manager |
| `model_get <dir>` | read the pinned model from `opencode.json` (preferred) or `opencode.jsonc` |
| `model_resolve <requested>` | `--model` → `$MODEL_PIN` → global config → prompt |
| `model_set <dir> <id>` | pin the model: rewrite in place, inject before the closing brace, or create a minimal `opencode.jsonc`; comment-aware |
| `mf_set` / `mf_keep` / `mf_installed` | key=value uninstall-manifest bookkeeping |

## Environment variables

| Variable | Read by | Meaning |
|----------|---------|---------|
| `MODEL_PIN` | `new-project.sh` | default model to pin when `--model` isn't given |
| `GITHUB_USER` | `new-project.sh`, `projects.sh`, `relink_placeholders` | owner fallback when `gh` can't tell (no auth) |
| `GITHUB_SSH_BASE` | `new-project.sh`, `projects.sh` | remote URL base prepended verbatim as `"${BASE}${OWNER}/${NAME}.git"` — must include the separator (`git@github.com:` default, or `file:///tmp/fake/` for tests) |
| `ROE_PROJECTS_TTL` | `projects.sh` | project-list cache TTL in seconds (default 900) |
| `XDG_CACHE_HOME` | `projects.sh` | where the project cache lives (`$XDG_CACHE_HOME/remote_opencode_sync/`) |
| `UNINSTALL_STATE_DIR`, `UNINSTALL_MANIFEST` | `setup-machine.sh`, `uninstall.sh` | where the uninstall manifest is written / read |
| `OC_SYNC_DIR` | `bootstrap.sh` | override the toolkit install directory (default `~/.local/share/remote_opencode_sync`) |

## Passing advanced options through `roe`

Because `roe` forwards `"$@"` verbatim, every script flag is reachable from `roe` — the
short, memorable command front and the full flag set behind it:

```
roe new side-quest --model opencode/thinking-m          # pin a model on create
roe new infra --setup                                   # auto-run setup if prereqs missing
roe adopt . --name legacy --resolve ask --no-scan       # adopt with tuned conflict handling
roe adopt legacy --force                                # repoint an existing origin
roe projects --refresh                                  # bypass the cache
roe projects docs                                      # substring filter
roe clone docs --dir ../proj/docs                       # clone into a specific path
roe clone bob/design-notes                              # clone a repo owned by someone else
roe desync -y                                           # non-interactive freeze-out
roe uninstall --dry-run                                 # preview before removing anything
MODEL_PIN=opencode/small roe new lite                   # env-var defaults apply too
ROE_PROJECTS_TTL=30 roe projects --refresh             # nudge the cache TTL
```

## Exit codes

- Scripts: `0` on success, `1` on any detected error (missing prereq, collision, bad
  flag, aborted confirmation, scan failure, …). `new-project.sh` also uses `1` when
  `--resolve` is invalid or too few arguments are given.
- `roe`: `0` on success; `2` for `roe help`/usage and unknown commands (and `roe model`
  with too many arguments). Anything the `exec`'d script returns passes through.
- Scripts with `-h/--help` exit `0` when help is printed.