# Daily Workflow Reference

How the whole system works day to day. Read `PLAN.md` first for the architecture; this is
the practical playbook.

## The golden rules

- Git is the source of truth for **code and progress**.
- One machine actively works at a time.
- The tree must be clean and pushed at every session boundary.
- The `AGENTS.md` rules in each project do the real work; the `session-sync` plugin is a
  backup that catches leftovers.

## New project (from any machine)

```
roe new <name>
```

That's `scripts/new-project.sh <name>` under the hood (`roe` runs it from anywhere; the
script spelling works from the toolkit root too).

Pre-flight checks `git`, `gh`, and auth, then creates a **private** GitHub repo, clones
it, seeds `AGENTS.md`, `CONTINUE.md`, `opencode.jsonc`, `.gitignore`, `.env.example`,
commits, and pushes. Then:

```
cd <name>
opencode
```

## Adopt an existing project (already-started folder)

```
roe adopt <dir> [--name <repo>] [--resolve append|ask|skip|overwrite] [--no-scan] [--force]
```

- Preserves existing git history; initializes if the dir isn't a repo; won't repoint an
  existing `origin` without `--force`.
- Seeds templates without clobbering; `--resolve` (default `append`) appends the workflow
  rules/ignore patterns behind a marker and reports what it skipped.
- `--scan` (default) drops a FIRST STEP into `CONTINUE.md` telling the first opencode
  session to scan the codebase and fill `AGENTS.md` Project overview + Status.
  `--no-scan` makes it ask you for the background instead.
- Requires a git identity — `scripts/setup-machine.sh` configures one from GitHub.

## Updating the toolkit

Once installed, either re-run the bootstrap curl command or:

```
roe update
```

Pull + setup + placeholder re-link. Restart opencode afterward to load a refreshed plugin.

## New/unseen machine — Stage 1 (once per machine)

```
roe setup      # = scripts/setup-machine.sh (lazy version)
# or read docs/machine-setup.md and do it by hand
```

Installs tools, `gh auth login`, SSH key, a global git identity from your GitHub profile,
the sync plugin, the `roe` command (`~/.local/bin` symlink + PATH entry), and an uninstall
manifest (used by `roe uninstall` / `scripts/uninstall.sh` to remove it all later).

The plugin is loaded in every opencode session on the machine, but **only acts in projects
carrying the `.opencode/toolkit` marker** that `new-project.sh` seeds — other projects are
never touched. To disable it for a single working copy: `touch .opencode/state/no-session-sync`
(local only, gitignored).

## New/unseen machine — Stage 2 (once per project)

```
gh repo clone <name>
cd <name>
# install deps (npm install / pip install / etc.) — deps are never synced
opencode
```

The plugin pulls, the `AGENTS.md` rules read `CONTINUE.md` and you're oriented.

> **Skipped Stage 1 (setup-machine.sh)?** You can still do the above — the rules travel
> inside the repo and will run. What you give up: the session-sync plugin (no auto-pull on
> start, no `wip:` backups on idle), a registered SSH key (SSH pushes fail), and an
> auto-set git identity (commits fail until you set `user.name`/`user.email`). Stage 1 is
> once per machine, idempotent, and stops at warnings — run it whenever.

## Daily start

```
cd <project>
opencode
```

Orients you automatically (`CONTINUE.md` + auto-reconcile of any abandoned session).
Work. That's it — commits and pushes happen per task (rules) and on idle (plugin).

## Stopping / switching machines

Just close the laptop. At minimum the idle-hook snapshot pushed a `wip:` commit and the
rules kept `CONTINUE.md` current. On the next machine, `opencode` re-orients you.

If you're at a natural session boundary, you can also say: "finalize this session" — the
rule #7 (or `/handoff`) writes a clean `LAST SESSION` block, closes the session log with
`END`, and pushes.

## Explicit commands (manual fallbacks)

Defined per-project in `opencode.jsonc`:

- `/resume` — pull, reconcile, orient from `CONTINUE.md`.
- `/handoff` — finalize session: close log, refresh `LAST SESSION`, commit, push.
- `/sync` — commit + push any pending changes now.

You should never *need* these; they exist for explicit control and edge cases.

## Conflicts

The plugin prefers `git pull --rebase`. If it fails (rare), the plugin logs an error and
you resolve once:

```
git status          # see conflicted files
# edit to resolve, then:
git add <files>
git rebase --continue
git push
```

Note it in `CONTINUE.md`. Conflicts usually mean two machines edited the same lines.

## Snapshot / `wip:` commits

`wip: <host> <timestamp>` commits are the plugin's automatic safety net when you go
idle with uncommitted work. They are safe to keep as-is. If you ever want a tidy history,
squash them (interactive rebase) — they carry real content you can review.

## Work outside opencode

Direct terminal/editor edits (not done through opencode) don't fire session events, so
they sync at the next session start/idle rather than in real time. Still safe: the
session start plumbing fetches and rebases, and idle snapshots are committed.

## Advanced option: opencode server mode

For heavy tasks, you can run opencode in **server mode on the desktop** and drive that
same live session from the light laptop (TUI/IDE/web client). No git sync needed for that
session at all — it *is* one session.

- Start the server on the desktop: `opencode serve --port 4040` (see opencode docs).
- Connect from the light laptop and work; when done, everything is already on the desktop,
  then push as usual.

Reason not to rely on this as your primary flow: it requires both machines on at once and
a network path between them. It complements, not replaces, git sync.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "start pull failed" logged | resolve rebase conflict (see above), then continue |
| "stash pop conflicted" | run `git stash pop` manually and resolve |
| Idle snapshot not pushing | check `git status`; remote down? push later manually |
| Plugin not syncing a project | project lacks the `.opencode/toolkit` marker — run `roe adopt . --resolve append` to adopt it |
| Permanently stop auto-sync on one copy | `touch .opencode/state/no-session-sync` (local, gitignored) — or `rm .opencode/toolkit` to mark the repo non-toolkit |
| Remove the toolkit | `roe uninstall` (or `~/.local/share/remote_opencode_sync/scripts/uninstall.sh`) + answer the questionnaire |
| Plugin not running | confirm `~/.config/opencode/plugins/session-sync.js` exists; restart opencode — if it was never installed, this machine skipped `roe setup` |
| New machine, no projects yet | run `roe new <name>` or `gh repo clone <name>` |