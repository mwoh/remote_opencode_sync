# remote_opencode_sync — Cross-Device OpenCode Workflow Toolkit

Work with [opencode](https://opencode.ai) on whichever machine fits the task — the light
laptop for writing, planning, and docs; the desktop or heavy laptop for compiling and
heavy lifting — and pick up exactly where you left off on the next machine, with **zero
manual sync steps**.

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
- Conversation history stays on each machine's local opencode storage; what travels is the
  running summary in `CONTINUE.md` + `session-logs/` + git history — enough to fully re-orient.

See [PLAN.md](PLAN.md) for the full architecture.

## Install on any machine (one-liner)

On a brand-new machine, this is the only command you need to remember:

```
curl -fsSL https://raw.githubusercontent.com/mwoh/remote_opencode_sync/main/scripts/bootstrap.sh | bash
```

It installs prerequisites (git, gh, node, opencode), authenticates GitHub, sets up an SSH
key, and installs the global session-sync plugin — everything required before you `gh repo
clone` and `opencode` into a project. If opencode is already running on this machine,
restart it to load the plugin.

**Updates:** re-run the same command, or from an installed copy run:

```
~/.local/share/remote_opencode_sync/scripts/update.sh
```

Both pull the latest toolkit and re-run setup (idempotent). Restart opencode after an update
to load a refreshed plugin.

**Safer/pinned variant:** download, verify the current SHA from the latest release notes,
then run — do not pipe straight to `bash`:

```
curl -fsSL -o bootstrap.sh https://raw.githubusercontent.com/mwoh/remote_opencode_sync/v1.1.0/scripts/bootstrap.sh
shasum -a 256 bootstrap.sh   # compare against the latest release notes
bash bootstrap.sh
```

## Layout

```
PLAN.md                     the plan / architecture
templates/                  per-project files seeded by new-project.sh
  AGENTS.md.tpl             base prompt / workflow rules (Layer 1)
  CONTINUE.md.tpl           handoff log with LAST SESSION block
  opencode.jsonc.tpl        /resume, /handoff, /sync commands
  .gitignore.tpl            deps, builds, secrets excluded
  .env.example.tpl          secrets reference (real .env is gitignored)
plugins/
  session-sync.js           global zero-touch sync plugin (Layer 2)
scripts/
  bootstrap.sh              one-liner install/update entry point
  update.sh                 update an already-installed toolkit
  new-project.sh            create or adopt a project (see below)
  setup-machine.sh          lazy one-time machine setup
  lib.sh                    shared helpers (placeholders, package install)
docs/
  machine-setup.md          new-machine checklist (the first step)
  daily-workflow.md         everyday playbook + advanced options
```

### What each piece does

- **`plugins/session-sync.js`** — the zero-touch sync layer (Layer 2): auto-pull/rebase on
  session start, `wip:` snapshot on idle, CONTINUE.md + session log into context
  compaction. Installed once per machine — this is what makes sync automatic.
- **`templates/`** — what gets seeded into every project (Layer 1): the `AGENTS.md` rules,
  `CONTINUE.md` handoff log, `opencode.jsonc` fallback commands, `.gitignore`,
  `.env.example`. These travel *inside* the project repo.
- **`bootstrap.sh`** — the `curl | bash` entry point: clone the toolkit + run setup.
- **`setup-machine.sh`** — per-machine setup: tools, `gh auth`, SSH key, git identity,
  plugin install. Idempotent, safe to re-run.
- **`update.sh`** — refresh an installed toolkit: pull latest + re-run setup.
- **`new-project.sh`** — per-project, once: create (or adopt) the repo, seed the
  templates, first commit + push.
- **`lib.sh`** — internal helpers; you never call it directly.

In one line: **setup scripts are once per machine**, **`new-project.sh` is once per
project**, and **the plugin is zero daily**.

## Setup

> **Path note:** all `scripts/…` commands below assume you're inside the toolkit clone.
> After the one-liner that's `~/.local/share/remote_opencode_sync` — already cloned for
> you.

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
scripts/setup-machine.sh
```

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
scripts/new-project.sh <repo-name>
```

This checks `git`/`gh`/auth (fails fast with guidance, or `--setup` hands off to
`setup-machine.sh`), creates a **private** GitHub repo, seeds the templates, and makes the
first commit + push. Then:

```
cd <repo-name>
opencode
```

## Adopting an existing project

Already have a folder full of code/notes you want to bring into the flow? No need to start
from an empty repo: `--existing` creates a new **private** GitHub repo for the folder and
pushes your existing history into it.

```
scripts/new-project.sh --existing <dir>
```

- Default repo name = basename of the directory (override with `--name <repo>`).
- Existing git history (if any) is **preserved**; if the dir isn't a repo it's initialized.
- Refuses to repoint an existing git `origin` unless you pass `--force`.
- Won't clobber existing files (`AGENTS.md`, `.gitignore`, …). `--resolve` controls conflicts:
  - `append` (default): appends the workflow rules + ignore patterns behind a marker,
    skips the rest, and prints a clear "things to review" list.
  - `ask`: interactive per-file prompt (skip / append / overwrite / view template).
  - `skip` / `overwrite`: never touch / always replace.
- `--scan` (default): writes a FIRST STEP telling the first opencode session to scan the
  codebase and fill in `AGENTS.md`'s Project overview + `CONTINUE.md`'s Status, then
  propose next steps. Pass `--no-scan` to have it ask you for the background instead.

Requires a git identity (`git config user.name/email`) — `scripts/setup-machine.sh` sets
it from your GitHub profile automatically.

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
The plugin pulls and orients you from `CONTINUE.md`. Work, close the laptop, switch
machines, and repeat. **No `/resume`, no `/handoff` needed** — those commands exist only
as manual fallbacks.

## Manual fallback commands

Defined per-project in `opencode.jsonc`:

- `/resume` — pull, reconcile any abandoned session, orient from `CONTINUE.md`.
- `/handoff` — finalize the session (close log, refresh `LAST SESSION`, commit, push).
- `/sync` — commit + push any pending changes now.

You should never *need* them; they're for explicit control and edge cases.

## Only manual moments (by design)

- One-time machine setup (auth, SSH keys).
- A real merge conflict (`git pull --rebase` failure) — rare, avoided by the
  one-machine-at-a-time rule. See [docs/daily-workflow.md](docs/daily-workflow.md).
- Work done entirely outside opencode — safe, but syncs at the next session start/idle
  instead of in real time.

## Advanced: opencode server mode

For heavy tasks you can run opencode **server mode on the desktop** and drive that same
live session from the light laptop — no sync needed for that session. Complement, not a
replacement, for git sync. Details in [docs/daily-workflow.md](docs/daily-workflow.md).

## Uninstalling

Everything the install creates is tracked in a manifest
(`~/.local/state/remote_opencode_sync/uninstall.conf`), and the reverse installer
removes **only what it created**:

```
~/.local/share/remote_opencode_sync/scripts/uninstall.sh
```

- **Default (and `--yes`):** removes the toolkit clone, the session-sync plugin,
  and any git identity *setup configured* — and keeps your tool packages, `gh`
  login, and SSH key (all safe to have around).
- A short questionnaire (or `--no-tools`, `--no-auth`, `--no-ssh-key`,
  `--no-identity`, `--no-plugin`, `--no-clone`) opts in/out of each category.
  Tool packages are offered **per tool** and only if setup itself installed them —
  anything you already had is never removed.
- `--dry-run` previews every step without changing anything.
- Installs from before the manifest existed can't be attributed safely — the
  script removes the clone + plugin and tells you what it left alone.

**Your projects are never touched.** If you also want a project's sync files
(`AGENTS.md`, `CONTINUE.md`, `opencode.jsonc`, `.env.example`, `session-logs/`)
gone, delete them from that repo and revert the `remote_opencode_sync` marker
section of its `.gitignore` — the uninstaller won't do it for you.

## Security

- Private repos only; never commit secrets. `.env` is gitignored; commit only `.env.example`.
- The plugin only runs `git`/filesystem commands — network use is just git fetch/push.