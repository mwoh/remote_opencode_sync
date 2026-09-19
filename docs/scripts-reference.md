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
| `status.sh`                | `roe status [<dir>]`       | is it a valid roe project; what does it need? |
| `pull.sh`                  | `roe pull [<dir>]`         | fetch + clean rebase (manual pull) |
| `push.sh`                  | `roe push [<dir>]`         | push committed state (refuses non-fast-forward) |
| `upgrade.sh`               | `roe upgrade [<dir>]`      | non-destructive refresh of a project's seed files |
| `track.sh`                 | `roe track [<dir>]`        | see/change what a project syncs (list / ignore / unignore / TUI) |
| `track_tui.py`             | (invoked by `track.sh`)    | curses TUI for `roe track` (python3 stdlib only) |
| `history.sh`               | `roe history <sub> [<dir>]`| backup/list/show this machine's session history for a project |
| `history.py`               | (invoked by `history.sh`)  | read-only opencode-db exporter/reader (python3 stdlib only) |
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
status)      require "$SC_STATUS"       && exec "$SC_STATUS"     "$@" ;;
pull)        require "$SC_PULL"         && exec "$SC_PULL"       "$@" ;;
push)        require "$SC_PUSH"         && exec "$SC_PUSH"       "$@" ;;
upgrade)     require "$SC_UPGRADE"       && exec "$SC_UPGRADE"     "$@" ;;
track)       require "$SC_TRACK"         && exec "$SC_TRACK"       "$@" ;;
history)     require "$SC_HISTORY"       && exec "$SC_HISTORY"     "$@" ;;
uninstall)   require "$SC_UNINSTALL"    && exec "$SC_UNINSTALL"  "$@" ;;
```

There are only three shapes of argument handling to keep in mind:

1. **Complete pass-through** — `roe new`, `roe setup`, `roe update`, `roe status`,
   `roe pull`, `roe push`, `roe upgrade`, `roe track`, `roe history`, `roe desync`,
   `roe resync`, `roe uninstall` forward `"$@"` unchanged. Anything the script accepts,
   `roe` accepts identically, including `--help`. The five sync commands take one optional
   argument — the project directory, defaulting to the current directory (`roe status
   ~/work/project`); `roe track` also resolves the project by walking up to the marker, so
   it works from any subdirectory. `roe history` is pass-through to `history.sh` and takes
   its own subcommand first (`roe history backup`, `roe history list`, `roe history show
   <id>`), likewise walked up to the marker.

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

3. **Inline commands with no script** — `roe version` (reports the installed version
   and the latest release tag on the toolkit's origin, hinting `roe update` when behind;
   any `vX.Y.Z` tag list works via `git ls-remote`, so it needs no gh/jq and degrades
   gracefully offline), `roe help`, and `roe model [id]`. `roe model` reads/edits the
   project's `opencode.json(c)` directly via `lib.sh` helpers; there is no `model.sh`.
   `roe help` prints `roe`'s own usage.

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
scripts/projects.sh list [--refresh] [--dir <path>] [--no-fetch] [name...]
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
- **Local copies**: each listed repo is annotated with whether (and where) it already
  exists locally, and that copy's state. The scan root is `--dir <path>` if given, else the
  current directory, or a project's parent when run from inside a project (so siblings are
  found). Only the root itself and its immediate children are inspected; a child counts if
  it carries the `.opencode/toolkit` marker. Local copies are matched to repos by their git
  origin basename (`x.git`→`x`), falling back to the directory name — a renamed clone dir
  still matches.
  - The `LOCAL` column shows `-` (not here), `here`, or `./dir`, plus a state:
    `clean` / `dirty N` / `ahead N` / `behind N` / `diverged (A ahead, B behind)` /
    `unknown (no upstream)` / `unknown (not a git work tree)`, prefixed `desynced · ` on
    the local opt-out.
  - **Each local copy is `git fetch`ed by default** so the state is accurate (the remote
    repo scan stays cached; only local copies are fetched). `--no-fetch` uses local
    tracking refs instead — faster, possibly stale. A failed fetch renders `offline?`.
  - A trailing **"other local roe projects"** section lists local projects whose name
    didn't match any repo in your GitHub list (unpublished, a different owner, or a
    failed/offline remote scan).
- Offline fallback: if a live scan fails but a cache exists, it shows the cached rows
  with a note; with no cache at all it errors, printing the underlying `gh:` stderr line.
  It suggests `roe setup` **only** when `gh auth status` actually fails, so a non-auth
  failure (network drop, bad flag) isn't misdiagnosed as an auth problem. The local
  section is still printed even when the remote scan fails.

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

## `status.sh` — is a project valid, and what does it need?

```
roe status [<dir>]       # default: current directory
```

Read-only advisory (the only write is a `git fetch`). Checks the `.opencode/toolkit`
marker (a directory without it is "not a remote_opencode_sync project"), then reports the
working copy's sync state and names the exact next command:

| State | Reported as | Exit |
|-------|-------------|------|
| valid + everything current | `state: all caught up` | 0 |
| ahead of upstream | `state: ahead by N — run: roe push` | 2 |
| behind upstream | `state: behind by N — run: roe pull` | 2 |
| diverged | `state: diverged (N ahead, M behind) — reconcile with: git pull --rebase` | 2 |
| dirty tree | `state: N uncommitted change(s) — commit them, then push` | 2 |
| local desync opt-out | `desynced on this machine (no-session-sync opt-out)` | 2 |
| project seed drift | `seed: drifted from the current toolkit — run: roe upgrade` | 2 |
| toolkit behind | `toolkit: installed X, latest Y — run: roe update` | 2 |
| not a roe project | `not a remote_opencode_sync project` | 1 |
| not a git repo / no origin / no upstream | sync is impossible (message) | 1 |

Seed drift is the same `lib.sh` predicate `upgrade.sh` uses (`project_seed_stale`), so
status and upgrade can never disagree. The trailing health lines (pinned model, plugin
installed here, tracking branch) are informational only — they never affect the exit code.

Env: none.

## `pull.sh` — fetch + clean rebase (manual pull)

```
roe pull [<dir>]         # default: current directory
```

The manual counterpart of the plugin's session-start ritual (see
`plugins/session-sync.js`): requires the toolkit marker and an upstream, fetches, and if
behind runs `pull --rebase`, stashing any local dirt first and popping it back afterwards.
Exits 0 when pulled (or already up to date), 1 when the pull/rebase fails or the directory
isn't a roe project. On stash-pop conflicts it completes the pull and tells you to run
`git stash pop` yourself.

Env: none.

## `push.sh` — push committed state (manual push)

```
roe push [<dir>]         # default: current directory
```

The outbound half. Requires the marker and an upstream; fetches first and **refuses** a
non-fast-forward (remote ahead) so it can never clobber commits made elsewhere — it tells
you to `roe pull` instead. Exits 0 when pushed (or nothing to push), 1 on refusal/failure.

Env: none.

## `upgrade.sh` — refresh a project's sync layer to the current toolkit

```
roe upgrade [<dir>]      # default: current directory
```

Non-destructive refresh of an existing roe project, so it speaks the current toolkit's
dialect (newer rules, commands, ignore patterns). Refuses to run unless the directory
carries the marker (`roe adopt` first) and the working tree is clean (it never bundles your
work). Sequence:

1. Pulls first (`fetch` + `pull --rebase` when behind) so the refresh sits on the latest.
2. Refreshes only what is missing or drifted:
   - `.opencode/toolkit` → rewritten to the current marker content if it drifted.
   - `opencode.json(c)` → the `resume`/`handoff`/`sync` command block is restored **without
     touching the model or other keys** (comment-aware `jsonc_inject_block`); if the
     `command` key exists but is incomplete, it is left alone and flagged for a manual
     merge from `templates/opencode.jsonc.tpl`. With **no** config at all it seeds a fresh
     `opencode.jsonc` from the template (model pinned if resolvable).
   - `AGENTS.md` → `## 1. Session start` rules appended only if the block is missing; a
     missing file is seeded from `AGENTS.md.tpl`. Marked blocks are never re-appended.
   - `.gitignore` → the `# --- added by remote_opencode_sync ---` patterns appended only if
     the marker is missing.
   - `session-logs/` + `.gitkeep` ensured.
3. On a **desynced** copy (`no-session-sync` opt-out) it refreshes only the committed files
   (marker/commands) and explicitly skips the `AGENTS.md`/`.gitignore` writes, because
   those files are skip-worktree-pinned locally and edits would be silently ignored.
4. Commits `chore: refresh remote_opencode_sync project seed (roe upgrade)` and pushes
   (`--follow-tags`) when anything changed; otherwise prints "nothing to update" (exit 0).

> **`roe upgrade` (this script) vs `roe update` (`update.sh`):** upgrade refreshes a
> *project's* seeded files; update upgrades the *toolkit itself*. Typically: `roe update`,
> then `roe status` to find which projects need `roe upgrade`.

Env: none.

## `track.sh` + `track_tui.py` — see and change what a project syncs

```
roe track [<dir>]                          # interactive curses TUI (default: cwd)
roe track --list [<dir>]                   # three plain lists (pure bash, no python)
roe track --ignore <path>... [--dir <dir>] # stop <path> syncing
roe track --unignore <path>... [--dir <dir>] # let <path> sync again
```

Why this exists: the idle `wip:` snapshot does `git add -A` (see `plugins/session-sync.js`),
so **`.gitignore` is the real boundary of "what syncs"** — any file not ignored is already
part of the sync, anywhere in a working copy. `roe track` makes that boundary explicit and
editable across the three states:

| State | Meaning | `roe track` action |
|-------|---------|--------------------|
| **Tracked** | committed in history, synced | *ignore* → append the pattern to the roe `.gitignore` block + `git rm --cached` (the file stays on disk, it just stops syncing) |
| **Untracked, not ignored** | not committed yet, but will sync on the next `wip:` snapshot | *ignore* → append the pattern to the roe block |
| **Ignored** | never syncs | *unignore* → remove the matching pattern from the roe block (re-adds the file if it exists) |

Key behaviours:

- **It only ever edits the `# --- added by remote_opencode_sync ---` block of the
  project's `.gitignore`.** Ignore rules the project's author wrote themselves (anywhere
  else in the file) are reported but never touched.
- **Project resolution walks up** from `<dir>`/the current directory to the nearest
  `.opencode/toolkit` marker (`lib.sh` `project_root`) — run it from any subdirectory of a
  project, and the TUI header shows `project: <basename> · root: <abs-path>` so there's no
  doubt what you're editing.
- **Paths are project-root-relative and escape-proof:** a flagged path is resolved against
  the project root and `...`/absolute paths that leave it are refused (exit 1).
- **Idempotent:** re-ignoring an already-ignored file is a no-op; no duplicate patterns.
- **Changes stay uncommitted.** They travel via the normal flow (your next commit or the
  idle `wip:` snapshot), at which point the `.gitignore` rule propagates to every machine.
  Caveat (printed in the TUI): gitignore never un-tracks *historical* files on its own — a
  file already in history on another machine stays "tracked" there until the next pull
  re-applies the rule.
- The bare `roe track` runs the **curses TUI** (`track_tui.py`) when stdin/stdout are a
  terminal and python3 std. `curses` is present; otherwise it prints the same `--list`
report and exits 0. The TUI is a thin presentation layer — all mutation shells back to
`track.sh` flags, which are the only tested/scriptable surface.

The `track_tui.py` TUI: three panes (Tracked / Untracked / Ignored) with per-pane counts,
`Tab`/`1`/`2`/`3` to switch, `↑`/`↓`/`j`/`k` to move (page with `PgUp`/`PgDn` or `b`/`f`),
`Enter`/`Space` to ignore/unignore, `r` to refresh, `h`/`?` help, `q`/`Esc` to quit;
resizes (`KEY_RESIZE`) and color pairs are handled. python3 **standard library only**
(no pip packages).

| Option | Meaning |
|--------|---------|
| `[<dir>]` | project to act on (default: current dir; walked up to the marker). For the TUI/`--list` |
| `--list` | print the three lists (used by the TUI and usable as the python-free fallback) |
| `--ignore <path>…` | stop each path syncing (append roe-block pattern; `git rm --cached` if tracked) |
| `--unignore <path>…` | let each path sync again (remove roe-block rule; `git add` if it exists) |
| `--dir <dir>` | explicit project directory for `--ignore`/`--unignore` (paths there are root-relative) |
| `-h`, `--help` | usage |

Exit codes: `0` success/no-op; `1` not a roe project, not a git work tree, a path escaped
the root, or a `--unignore` asked to modify a rule outside the roe block.

Env: none.

## `history.sh` + `history.py` — per-machine session-history backups

```
roe history backup [<dir>] [--db <path>] [--host <name>]   # archive this machine's sessions
roe history list   [<dir>] [--host <name>]                 # list archived sessions
roe history show <session-id> [<dir>] [--host <name>]      # markdown transcript
```

Why this exists: opencode stores **all** conversation history for **all** projects in one
local SQLite db (`~/.local/share/opencode/opencode.db`), not in your git projects — so
deleting that directory (a stray `rm -rf`, bad advice) loses the machine's entire chat
history. `history.sh` closes that hole: it exports **this project's** sessions for the local
machine into a compressed archive **inside the repo**, which the normal sync (or the idle
`wip:` snapshot) carries to every machine.

| Piece | What it does |
|-------|--------------|
| archive path | `<project>/opencode-history/<host>.jsonl.gz` — one **rolling** file per machine, keyed by short hostname (`--host` overrides) |
| `backup` | reads the db **read-only** (`mode=ro`), matches sessions to the project (by `project.worktree`, `project_directory.directory`, or `session.directory`), writes one JSONL record per session with every message and part's raw JSON |
| `list` | prints the archive's sessions (time · title · id · agent · message count) — no db touched |
| `show <id>` | renders one session as a markdown transcript (text/reasoning, `[tool: …]` markers); accepts an exact id or a **unique prefix** |

Key behaviours:

- **It never writes opencode's db.** `history.py` opens it with a `mode=ro` URI; anything
  that would mutate state stays in bash. This mirrors `track_tui.py` being
  presentation-only.
- **Only this project.** Sessions are matched by the working-tree/directory recorded in the
  db, so one machine's history for a *different* project is never included.
- **It works from any subdirectory** (`project_root` walk-up, like `roe track`) and refuses
  a directory without the `.opencode/toolkit` marker (exit 1).
- **Cross-machine recovery:** because the archive is committed in the project, any machine
  sees every machine's archive. `roe history list --host <other>` and
  `roe history show <id> --host <other>` read another machine's history. opencode has no
  "merge a db back in" API, so recovery is reading/replaying the transcript — the raw JSONL
  is kept for full fidelity and future tooling.
- **`/handoff` runs `roe history backup`** before its final commit; **`/sync` warns** when
  this machine's archive is missing or older than 7 days. That makes a forgetful machine
  visible before a disaster rather than after.
- **Privacy — an archive is the full raw transcript** (prompts + tool output). Keep a
  project's repo **private**. If `opencode-history/` is gitignored (as in this toolkit's own
  public repo, via `roe track --ignore opencode-history`), `backup` still writes the archive
  locally but prints a `will NOT sync` note — so an ignored archive is never mistaken for a
  syncing one.
- Re-running `backup` is idempotent (overwrites the host's single archive).

| Option | Meaning |
|--------|---------|
| `<dir>` | project (default: cwd; walked up to the `.opencode/toolkit` marker) |
| `--db <path>` | opencode db to read (**backup only**; default `$OPENCODE_DB` or `~/.local/share/opencode/opencode.db`) |
| `--host <name>` | machine key for the archive filename (default: `hostname -s`) |
| `-h`, `--help` | usage |

Exit codes: `0` success; `1` not a roe project, db not found/unusable, no archive for the
requested host, or no/ambiguous session match.

Env: `OPENCODE_DB` — override the opencode database path.

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
| `project_has_marker <dir>` / `project_desynced <dir>` | the `.opencode/toolkit` marker check and the `no-session-sync` opt-out check (the same answers the plugin uses) |
| `project_root <dir>` | walk up from `<dir>` to the nearest `.opencode/toolkit` marker and echo its absolute path (drives `roe track` from any subdirectory) |
| `project_commands_current <dir>` | any opencode config carries the full `resume`/`handoff`/`sync` fallback command set |
| `project_rules_current <dir>` | `AGENTS.md` carries the sync-rules block (`## 1. Session start` header or the append-block marker) |
| `project_gitignore_current <dir>` | `.gitignore` carries the `# --- added by remote_opencode_sync ---` marker |
| `project_seed_stale <dir>` | OR of the three above — exits 0 when the seeded sync layer drifted (drives `roe status` + `roe upgrade`) |
| `jsonc_inject_block <file> <blockfile>` | comment-aware JSON/JSONC injection of a multi-line block before the final closing brace (the block restore used by `roe upgrade`) |
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
roe projects --dir ~/Projects                          # scan a different root for local copies
roe projects --no-fetch                                 # skip fetching local copies (faster)
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
- `status.sh` uses the trio: `0` valid + everything current, `1` not a roe project / not
  a usable git working copy, `2` valid but an action is needed (see the report). This makes
  `roe status && roe pull` a safe scriptable gate.
- `track.sh` uses `0` success/no-op and `1` for not-a-roe-project / not-a-git-work-tree /
  escape / outside-the-roe-block, like the other scripts.
- `history.sh` uses `0` success and `1` for not-a-roe-project / db missing or unusable /
  no archive for the host / no-or-ambiguous session match.
- `roe`: `0` on success; `2` for `roe help`/usage and unknown commands (and `roe model`
  with too many arguments). Anything the `exec`'d script returns passes through.
- Scripts with `-h/--help` exit `0` when help is printed.