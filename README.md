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
  new-project.sh            create + seed a new private GitHub repo
  setup-machine.sh          lazy one-time machine setup
docs/
  machine-setup.md          new-machine checklist (the first step)
  daily-workflow.md         everyday playbook + advanced options
```

## Setup

### 1. First time on a new machine (once per machine)

Read [docs/machine-setup.md](docs/machine-setup.md), or run the lazy version:

```
scripts/setup-machine.sh
```

It installs prerequisites (git, gh, node, opencode), runs `gh auth login`, sets up an SSH
key, and installs the global session-sync plugin.

### 2. Clone the toolkit (so it exists on this machine too)

```
gh repo clone mwoh/remote_opencode_sync
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

## Working on an existing project

First time on a machine (once per project):

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

## Security

- Private repos only; never commit secrets. `.env` is gitignored; commit only `.env.example`.
- The plugin only runs `git`/filesystem commands — network use is just git fetch/push.