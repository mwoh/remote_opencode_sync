# ROE - remote_opencode_sync — Cross-Device OpenCode Workflow Toolkit

Work with [opencode](https://opencode.ai) on whichever machine fits the task — the light
laptop for writing, planning, and docs; the desktop or heavy laptop for compiling and
heavy lifting — and pick up exactly where you left off on the next machine, with **zero
manual sync steps**. After setup, every toolkit action is one short command: **`roe`**.

Git is the single source of truth for **both code and progress**. Each project carries
its own handoff log (`CONTINUE.md`) and running session log (`session-logs/`), kept
continuously committed + pushed by an opencode **base prompt** (Layer 1) and a global
**session-sync plugin** (Layer 2).

## How it works (short version)

- Every project is a **private GitHub repo**, seeded with workflow templates.
- The `AGENTS.md` base prompt in each project enforces the sync rules:
  read `CONTINUE.md` at session start, commit + push after each task, update the logs
  continuously, keep the tree clean, never commit secrets.
- A small global opencode plugin (`session-sync.js`) makes it zero-touch:
  - pulls/rebase on **session start** (auto-resume),
  - snapshots any uncommitted work as a `wip:` commit on **idle** (auto-backup),
  - injects `CONTINUE.md` + the session log into **context compaction** so continuity survives.
  - It is loaded on every machine but **only acts in projects that carry the toolkit's
    `.opencode/toolkit` marker** (`new-project.sh` seeds one into every project) — other
    projects are never touched; a local `.opencode/state/no-session-sync` file turns it
    off for a single working copy.
- Conversation history stays on each machine's local opencode storage; what travels is the
  running summary in `CONTINUE.md` + `session-logs/` + git history — enough to fully re-orient.

See [PLAN.md](PLAN.md) for the full architecture.

## Install on any machine (one-liner)

On a brand-new machine, this is the only command you need to remember:

```
curl -fsSL https://raw.githubusercontent.com/mwoh/remote_opencode_sync/main/scripts/bootstrap.sh | bash
```

It installs prerequisites (git, gh, node, opencode), authenticates GitHub, sets up an SSH
key and a git identity, and installs the global session-sync plugin — everything required
before you `gh repo clone` and `opencode` into a project. It also writes an uninstall
manifest so `scripts/uninstall.sh` can undo everything later. If opencode is already running
on this machine, restart it to load the plugin.

**Updates:** re-run the same command, or from an installed copy run:

```
roe update
```

(`scripts/update.sh` works too — `roe` is just a shortcut front-end; more below.)

Both pull the latest toolkit and re-run setup (idempotent). Restart opencode after an update
to load a refreshed plugin.

**Safer/pinned variant:** download, verify the current SHA from the latest release notes,
then run — do not pipe straight to `bash`:

```
curl -fsSL -o bootstrap.sh https://raw.githubusercontent.com/mwoh/remote_opencode_sync/v1.5.2/scripts/bootstrap.sh
shasum -a 256 bootstrap.sh   # compare against the latest release notes
bash bootstrap.sh
```

## The `roe` command

After setup, all the scripts have one front-end named **`roe`** — a symlink in
`~/.local/bin` that always runs the *current* toolkit, from any directory. You never
need to remember the paths under `~/.local/share/remote_opencode_sync/scripts/` again.

| Purpose | `roe` command | Under the hood |
| --- | --- | --- |
| Update the toolkit | `roe update` | `scripts/update.sh` |
| One-time machine setup | `roe setup` | `scripts/setup-machine.sh` |
| Create a new project | `roe new <name>` | `scripts/new-project.sh <name>` |
| Adopt an existing folder | `roe adopt <dir>` | `scripts/new-project.sh --existing <dir>` |
| List your synced projects | `roe projects` | `scripts/projects.sh list` |
| Clone a synced project | `roe clone <name>` | `scripts/projects.sh clone <name>` |
| Pin the model used here | `roe model [<id>]` | rewrites the project's `opencode.jsonc` |
| Stop this machine syncing a copy | `roe desync` | `scripts/desync.sh` |
| Undo desync | `roe resync` | `scripts/resync.sh` |
| Uninstall | `roe uninstall` | `scripts/uninstall.sh` |
| Version info | `roe version` | — |
| Help | `roe help` | — |

Everything after the command is passed through unchanged (`roe adopt ./x --resolve ask`,
`roe new foo --setup`, `roe uninstall --dry-run`). `create` is an alias for `new`; unknown
commands exit with `2`. Restart your shell (or `source ~/.bashrc`) if `roe` isn't found
yet — setup adds `~/.local/bin` to `PATH` if it was missing.

## Layout

```
PLAN.md                     the plan / architecture
AGENTS.md                   standing session instructions (keep-everything-in-sync mandate)
LICENSE                     MIT
templates/                  per-project files created/used by new-project.sh
  AGENTS.md.tpl             base prompt / workflow rules (Layer 1)
  CONTINUE.md.tpl           handoff log with LAST SESSION block
  opencode.jsonc.tpl        project config: /resume, /handoff, /sync + pinned model
  .gitignore.tpl            deps, builds, secrets excluded
  .env.example.tpl          secrets reference (real .env is gitignored)
  workflow-rules.md.tpl     rules-only block appended to an existing AGENTS.md on adopt
  .gitignore.append.tpl     ignore patterns appended to an existing .gitignore on adopt
plugins/
  session-sync.js           global zero-touch sync plugin (Layer 2)
bin/
  roe                       'roe' command front-end (symlinked into ~/.local/bin)
scripts/
  bootstrap.sh              one-liner install/update entry point
  update.sh                 update an already-installed toolkit
  new-project.sh            create or adopt a project (see below; resumable)
  projects.sh               list your synced projects / clone one onto this machine
  desync.sh                 stop one working copy from syncing (local only)
  resync.sh                 undo a desync
  setup-machine.sh          lazy one-time machine setup
  uninstall.sh              remove what setup created (see below)
  lib.sh                    shared helpers (placeholder relink, package install/remove, manifest)
docs/
  machine-setup.md          new-machine checklist (the first step)
  daily-workflow.md         everyday playbook + advanced options
  scripts-reference.md      every script, its options, and how roe wires through
  agent-handoff.md          takeover guide: current state, tests, release process
tests/
  features.sh               71-check sandbox e2e (fake gh) — run before any release
  model-features.sh         28-check model-helper regression
  plugin-test.mjs           15-check session-sync plugin harness
  shims/gh                  fake `gh` backing the sandbox
```

### What each piece does

- **`plugins/session-sync.js`** — the zero-touch sync layer (Layer 2): auto-pull/rebase on
  session start, `wip:` snapshot on idle, CONTINUE.md + session log into context
  compaction. Installed once per machine — but it only runs in projects that carry the
  `.opencode/toolkit` marker that `new-project.sh` seeds, so every other project is
  completely untouched. A local `.opencode/state/no-session-sync` file opts a single
  working copy out.
- **`templates/`** — what gets seeded into (or appended to) every project (Layer 1): the
  `AGENTS.md` rules, `CONTINUE.md` handoff log, `opencode.jsonc` fallback commands,
  `.gitignore`, `.env.example` — plus `workflow-rules.md.tpl` and `.gitignore.append.tpl`,
  rules/ignore blocks appended when adopting an existing project. These travel *inside* the
  project repo.
- **`bootstrap.sh`** — the `curl | bash` entry point: clone the toolkit + run setup.
- **`setup-machine.sh`** — per-machine setup: tools, `gh auth`, SSH key, git identity,
  plugin install. Also symlinks `roe` into `~/.local/bin` and adds that dir to `PATH` (if
  missing), so the toolkit is one word from any directory. Idempotent, safe to re-run.
- **`uninstall.sh`** — reverse of setup: removes only what the install created (per the
  uninstall manifest), with a per-category/per-tool questionnaire and `--dry-run`.
- **`update.sh`** — refresh an installed toolkit: pull latest + re-run setup.
- **`bin/roe`** — the `roe` command front-end (see above): a symlink target in the toolkit
  that dispatches every `scripts/…` tool; setup links it into `~/.local/bin` and records
  the link + PATH line in the manifest so uninstall removes exactly those. Since it
  resolves through the symlink (`readlink -f`), it always runs the toolkit it came from.
- **`new-project.sh`** — per-project, once: create (or adopt) the repo, seed the
  templates + the `.opencode/toolkit` marker (this is what tells the plugin a project uses
  the toolkit), first commit + push. Re-running after an interruption resumes, so a network
  blip mid-create/seed/commit/push is not fatal.
- **`projects.sh`** — per request: scan the user's GitHub repos for the `.opencode/toolkit`
  marker (`roe projects`, with a short-lived cache) and clone a compatible repo (`roe clone`).
- **`desync.sh` / `resync.sh`** — per working copy: opt one machine's copy of a project out
  of the sync loop (`roe desync`) and bring it back (`roe resync`). Local-only, never pushed.
- **`lib.sh`** — internal helpers (placeholder relink, package install/remove, uninstall
  manifest); you never call it directly.

In one line: **setup scripts are once per machine**, **`new-project.sh` is once per
project**, and **the plugin is zero daily**.

## Setup

> **Path note:** all `scripts/…` commands below assume you're inside the toolkit clone.
> After the one-liner that's `~/.local/share/remote_opencode_sync` — already cloned for
> you. Once setup linked the `roe` front-end into `~/.local/bin`, the same scripts run
> from any directory as `roe <command>` (see *The `roe` command* above).

There are three ways to get a machine ready, depending on what you're doing:

| You want to… | Run | What you get |
| --- | --- | --- |
| Full setup on a machine with nothing (lazy default) | the one-liner above (`curl \| bash`) | prerequisites, gh auth, SSH key, git identity, the session-sync plugin, and a local toolkit clone |
| The same, but the toolkit is already cloned here | `scripts/setup-machine.sh` | the machine side: prerequisites, gh auth, SSH key, git identity, the plugin — no re-clone |
| Just open a project that already exists on GitHub | *nothing* — skip to *Working on an existing project* | the project + its own `AGENTS.md` (Layer-1 rules); **no** plugin, **no** SSH key, **no** git identity |

> **Skipping setup?** You can still `gh repo clone` and work — the rules travel inside the
> repo and will run. You just won't get the zero-touch safety net (no auto-pull/rebase on
> session start, no automatic `wip:` backups on idle, no compaction continuity), and you'll
> have to handle auth + identity yourself — SSH pushes fail without a registered key, and
> commits fail until `user.name`/`user.email` are set. Catch up any time by running the
> one-liner or `setup-machine.sh` — both are idempotent.

The one-liner does the steps below automatically; by hand they are:

### 1. First time on a new machine (once per machine)

Read [docs/machine-setup.md](docs/machine-setup.md), or run:

```
roe setup
```

(same as `scripts/setup-machine.sh` — either works; `roe` is easier to find.)

It installs prerequisites (git, gh, node, opencode), runs `gh auth login`, sets up an SSH
key, a git identity (from your GitHub profile), and installs the global session-sync
plugin. Re-running is safe (idempotent).

### 2. Clone the toolkit (so it exists on this machine too)

Only needed if you haven't used the one-liner:

```
gh repo clone @@GITHUB_USER@@/remote_opencode_sync
```

## Creating a new project

From any machine:

```
roe new <repo-name>
```

(same as `scripts/new-project.sh <repo-name>` — either works; `roe` is just the shortcut)

This checks `git`/`gh`/auth (fails fast with guidance, or `--setup` hands off to
`setup-machine.sh`), creates a **private** GitHub repo, seeds the templates, and makes the
first commit + push. It also **pins the opencode model** in the project's `opencode.jsonc`
(your global config's model by default, or `--model <id>`) so every machine runs the same
one. Then:

```
cd <repo-name>
opencode
```

## Adopting an existing project

Already have a folder full of code/notes you want to bring into the flow? No need to start
from an empty repo: `--existing` creates a new **private** GitHub repo for the folder and
pushes your existing history into it.

```
roe adopt <dir>
```

(same as `scripts/new-project.sh --existing <dir>` — either works.)

- Default repo name = basename of the directory (override with `--name <repo>`).
- Existing git history (if any) is **preserved**; if the dir isn't a repo it's initialized.
- Refuses to repoint an existing git `origin` unless you pass `--force`.
- If the folder has uncommitted changes, adopt **warns** you that they'll be included in
  the import commit (and continues — they travel, they're not lost).
- With `--force`, the old `origin` is replaced and adopt says so, naming the previous URL
  (the old repo on its host is left untouched).
- Annotated git tags reachable from the pushed history travel too (`--follow-tags`).
- After the push, if you pushed a branch other than the remote's default (e.g. `master`
  into a fresh repo defaulting to `main`), adopt prints a hint to align them.
- Won't clobber existing files (`AGENTS.md`, `.gitignore`, …). `--resolve` controls conflicts:
  - `append` (default): appends the workflow rules + ignore patterns behind a marker,
    skips the rest, and prints a clear "things to review" list.
  - `ask`: interactive per-file prompt (skip / append / overwrite / view template).
  - `skip` / `overwrite`: never touch / always replace.
- `--scan` (default): writes a FIRST STEP telling the first opencode session to scan the
  codebase and fill in `AGENTS.md`'s Project overview + `CONTINUE.md`'s Status, then
  propose next steps. Pass `--no-scan` to have it ask you for the background instead.
- The model: your default (global config / `$MODEL_PIN` / `--model <id>`) is pinned into
  `opencode.jsonc` — unless the config already declares one, in which case that's kept and
  reported.

Requires a git identity (`git config user.name/email`) — `scripts/setup-machine.sh` sets
it from your GitHub profile automatically.

> **Interrupted mid-way?** Both `new` and `adopt` are resumable. If the network drops
> (or anything else stops them partway), simply **re-run the exact same command** — it
> detects the leftover clone/empty repo, skips create + seed + commit, and only finishes
> what's left (usually the push).

## Listing and cloning synced projects

Your GitHub account may hold many repos, but only the ones carrying the committed
`.opencode/toolkit` marker are remote_opencode_sync projects (the same marker the plugin
gates on). Discover them without cloning everything:

```
roe projects            # list your synced projects (cached ~15 min)
roe projects --refresh  # force a fresh scan
roe projects goals      # filter by substring
```

Then clone one straight onto this machine — it arrives fully synced (the marker, the
`AGENTS.md` rules, and the fallback commands all travel in the repo):

```
roe clone <name>        # or: roe clone owner/name
cd <name> && opencode
```

`roe clone` verifies the repo really is a synced project before cloning and reminds you if
the machine still needs `roe setup` (plugin / SSH key / git identity).

## Working on an existing project (a repo already on GitHub)

For a project that's already on GitHub — e.g. you created it on another machine — and you
want to open it here. First time on a machine (once per project):

```
gh repo clone <repo-name>
cd <repo-name>
# install deps (npm install / pip install / …) — deps are never synced
opencode
```

Every time after that, just:

```
cd <repo-name>
opencode
```

opencode auto-loads each project's `AGENTS.md` — there's no per-project config to set up.
The model pinned in the project's `opencode.jsonc` travels with the repo, so every machine
opens on the same model. The plugin pulls and orients you from `CONTINUE.md`. Work, close
the laptop, switch machines, and repeat. **No `/resume`, no `/handoff` needed** — those
commands exist only as manual fallbacks.

## Manual fallback commands

Defined per-project in `opencode.jsonc`:

- `/resume` — pull, reconcile any abandoned session, orient from `CONTINUE.md`.
- `/handoff` — finalize the session (close log, refresh `LAST SESSION`, commit, push).
- `/sync` — commit + push any pending changes now.

You should never *need* them; they're for explicit control and edge cases.

> **Migrating a project seeded by an older toolkit?** Older seeds used the
> `"prompt"` key for these commands, which the current opencode schema no longer
> accepts (it requires `"template"`). Fix an older project's config with:
> ```
> sed -i 's/"prompt":/"template":/g' opencode.jsonc
> ```
> then commit + push. New projects are unaffected (the template already uses `"template"`).

## Pinned model

Every project's `opencode.jsonc` carries a `model` key. Because the config travels inside
the repo and opencode's project config overrides the global one, **all machines work with
the same model** without touching each machine's global settings. It's set at creation from
your global config (or `roe new <name> --model <id>`); when adopting, an existing model in
the config is respected and kept. Change it any time:

```
roe model               # what's pinned in this project
roe model <id>          # change it, then commit + push to propagate
```

Note: a machine without access to the pinned provider will error at session start — exactly
as it would if you picked that model there manually.

## Only manual moments (by design)

- One-time machine setup (auth, SSH keys).
- A real merge conflict (`git pull --rebase` failure) — rare, avoided by the
  one-machine-at-a-time rule. See [docs/daily-workflow.md](docs/daily-workflow.md).
- Work done entirely outside opencode — safe, but syncs at the next session start/idle
  instead of in real time.

## Desyncing one machine's copy

If you want a single working copy to stop participating in the sync — keep the project
exactly as it is, but stop this machine from pulling, pushing, `wip:`-backing-up, or
following the sync rules — while the repo and every other machine keep collaborating:

```
roe desync          # run inside the project directory (confirm with -y if you prefer)
```

This is purely local and reversible:

- Writes `.opencode/state/no-session-sync` (gitignored) — the global plugin becomes a
  no-op in this working copy.
- Strips the sync-rules block from the **local** `AGENTS.md` (keeping the Project
  overview) and pins that edit with `git update-index --skip-worktree` so it can never
  be committed or pushed by accident.

The committed sync files (`AGENTS.md` in the repo, `opencode.jsonc`, `CONTINUE.md`,
`session-logs/`, the marker) stay put — other machines keep using them. This copy just
frozen out from that point on. Undo:

```
roe resync
```

> `roe` only ever acts in marker projects. In any other opencode project the plugin is a
> complete, silent no-op — no git commands, no logs.

## Advanced: opencode server mode

For heavy tasks you can run opencode **server mode on the desktop** and drive that same
live session from the light laptop — no sync needed for that session. Complement, not a
replacement, for git sync. Details in [docs/daily-workflow.md](docs/daily-workflow.md).

## Uninstalling

Everything the install creates is tracked in a manifest
(`~/.local/state/remote_opencode_sync/uninstall.conf`), and the reverse installer
removes **only what it created**:

```
roe uninstall
```

(same as `~/.local/share/remote_opencode_sync/scripts/uninstall.sh` — either works.) It also
removes the `roe` symlink and the PATH line setup added, so uninstall is a full reverse.

- **Default (and `--yes`):** removes the toolkit clone, the session-sync plugin,
  and any git identity *setup configured* — and keeps your tool packages, `gh`
  login, and SSH key (all safe to have around). The clone deletion is double-guarded:
  the path must look like a toolkit clone and live under `$HOME`, so a mis-pointed
  manifest can never take out an unrelated directory.
- A short questionnaire (or `--no-tools`, `--no-auth`, `--no-ssh-key`,
  `--no-identity`, `--no-plugin`, `--no-clone`) opts in/out of each category.
  Tool packages are offered **per tool** and only if setup itself installed them —
  anything you already had is never removed.
- `--dry-run` previews every step without changing anything.
- Installs from before the manifest existed can't be attributed safely — the
  script removes the clone + plugin and tells you what it left alone.

**Your projects are never touched.** To stop a single working copy from syncing while
everyone else keeps going, use `roe desync` (local only); `roe resync` reverses it. If you
truly want a project's sync files removed from the **repo** (for every machine), delete
them from that repo yourself and revert the `remote_opencode_sync` marker section of its
`.gitignore` — the uninstaller won't do it for you.

## Security

- Private repos only; never commit secrets. `.env` is gitignored; commit only `.env.example`.
- The plugin only runs `git`/filesystem commands — network use is just git fetch/push.