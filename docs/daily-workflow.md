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
roe new <name> [--model <id>]
```

That's `scripts/new-project.sh <name>` under the hood (`roe` runs it from anywhere; the
script spelling works from the toolkit root too).

Pre-flight checks `git`, `gh`, and auth, then creates a **private** GitHub repo, clones
it, seeds `AGENTS.md`, `CONTINUE.md`, `opencode.jsonc`, `.gitignore`, `.env.example`,
commits, and pushes. The model pinned in `opencode.jsonc` comes from `--model <id>`,
`$MODEL_PIN`, or your global opencode config (in that order) — every machine then opens
the project on that model. Then:

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
- Uncommitted changes in the folder get bundled into the import commit — adopt **warns**
  you first (nothing is lost).
- Under `--force`, the old `origin` is replaced and adopt names the previous URL (the old
  repo on its host is left untouched).
- Annotated git tags travel too (`--follow-tags`), and if you pushed a branch that isn't
  the remote's default (e.g. `master` into a repo defaulting to `main`) adopt prints a
  hint to align them.
- Seeds templates without clobbering; `--resolve` (default `append`) appends the workflow
  rules/ignore patterns behind a marker and reports what it skipped.
- `--scan` (default) drops a FIRST STEP into `CONTINUE.md` telling the first opencode
  session to scan the codebase and fill `AGENTS.md` Project overview + Status.
  `--no-scan` makes it ask you for the background instead.
- Pins the model in `opencode.jsonc` — but an existing model in the config is respected
  and kept (reported at adopt time). See *Pinned model* below.
- Requires a git identity — `scripts/setup-machine.sh` configures one from GitHub.

> **Interrupted `new`/`adopt`?** Re-run the exact same command. It detects the previous
> attempt (a leftover clone pointing at the target URL, or an empty repo that never got
> seeded), skips create/seed/commit, and finishes what's left — usually just the push.
> A genuine collision (a non-empty repo you didn't create) is still refused with a hint.

## Listing and cloning synced projects

`roe projects` scans your GitHub account for repos carrying the committed
`.opencode/toolkit` marker (the same marker the plugin runs on) and lists only those —
nothing is cloned:

```
roe projects            # list synced projects (cached ~15 min)
roe projects --refresh  # rescan now
roe projects goals      # filter by substring
```

`roe clone <name>` verifies the repo is synced, clones it via SSH, and reminds you if
`roe setup` is still needed on this machine:

```
roe clone <name>        # or: roe clone owner/name
cd <name> && opencode   # already synced — clone carries marker, rules, commands
```

## Opting a machine out (`roe desync`)

To freeze one working copy out of the sync loop — this machine stops pulling, pushing,
`wip:`-backing-up, and following the rules, while the repo and other machines keep
collaborating — run inside the project dir:

```
roe desync              # local-only; -y to skip the confirm
roe resync              # undo, any time
```

- Writes the gitignored `.opencode/state/no-session-sync` — the plugin stops acting here.
- Strips the sync rules from the **local** `AGENTS.md` (keeps the Project overview) and
  pins the edit with `git update-index --skip-worktree`, so it can never commit/push.
- Committed files (`opencode.jsonc`, `CONTINUE.md`, `session-logs/`, the marker, the repo
  `AGENTS.md`) are untouched — other machines keep using them. The copy is frozen from the
  moment desync runs.

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

Find and clone a synced project:

```
roe projects                # which of my repos carry sync support?
roe clone <name>            # clone one (or: gh repo clone <name>)
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

## Checking sync state / manual pull-push-upgrade

The plugin keeps the daily flow automatic, but the deterministic, `git status`-style
inspection is a `roe` command away (run in a project, or pass a directory):

```
roe status               # what does this project need right now? (read-only)
```

It fetches and prints the single most useful state line (exit `0` = all caught up, `2` =
an action is needed, `1` = not a roe project), then the details — including push/pull
counts, uncommitted files, a desync opt-out, seed drift, and a stale toolkit:

| Status says | Do this |
| --- | --- |
| `state: ahead by N — run: roe push` | `roe push` (push committed state) |
| `state: behind by N — run: roe pull` | `roe pull` (fetch + clean rebase) |
| `state: diverged (…)— reconcile with: git pull --rebase` | resolve the rebase (see Conflicts) |
| `state: N uncommitted change(s)` | commit them (or close the laptop — idle `wip:` catches it) |
| `desynced on this machine` | intentional — run `roe resync` to rejoin |
| `seed: drifted — run: roe upgrade` | `roe upgrade` to refresh this project's sync layer |
| `toolkit: installed X, latest Y — run: roe update` | `roe update` then re-check `roe status` |

`roe pull` / `roe push` mirror the plugin's session-start ritual (stash-safe rebase, and a
push that refuses to clobber remote work) — manual counterparts to also work fine if the
plugin isn't installed on a machine. `roe upgrade` refreshes a project's seeded files
(marker, fallback commands **keeping the pinned model**, missing rules/ignore blocks) from
the current toolkit, non-destructively — the toolkit itself stays on `roe update`.

## Explicit commands (manual fallbacks)

Defined per-project in `opencode.jsonc`:

- `/resume` — pull, reconcile, orient from `CONTINUE.md`.
- `/handoff` — finalize session: close log, refresh `LAST SESSION`, commit, push.
- `/sync` — commit + push any pending changes now.

You should never *need* these; they exist for explicit control and edge cases.

> **Migrating a project seeded by an older toolkit?** Older seeds used the `"prompt"`
> key for these commands, which the current opencode schema rejects (it requires
> `"template"`). Fix it with:
> ```
> sed -i 's/"prompt":/"template":/g' opencode.jsonc
> ```
> then commit + push.

## Pinned model

Each project's `opencode.jsonc` carries a `model` key. It travels with the repo and
overrides each machine's global opencode config, so every machine runs the same model.

- Read it: `roe model` (shows what's pinned in the current directory).
- Change it: `roe model <id>`, then commit + push — pull on the other machines and they
  pick it up.
- Set it at creation: `roe new <name> --model <id>` (default: your global config's
  model). Adopting respects a model your config already declares.
- Caveat: a machine without access to the pinned provider errors at session start — the
  same as choosing that model there manually.

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
| Wrong model being used | `roe model` to check the pin, `roe model <id>` to change it, then commit + push |
| Plugin not syncing a project | project lacks the `.opencode/toolkit` marker — run `roe adopt . --resolve append` to adopt it |
| `roe new`/`adopt` failed partway | re-run the same command — it resumes (skips create/seed/commit, finishes the push) |
| Permanently stop auto-sync on one copy | `roe desync` (undo: `roe resync`) — or `touch .opencode/state/no-session-sync` manually |
| Find my synced projects / clone one | `roe projects` / `roe clone <name>` |
| Remove the toolkit | `roe uninstall` (or `~/.local/share/remote_opencode_sync/scripts/uninstall.sh`) + answer the questionnaire |
| Plugin not running | confirm `~/.config/opencode/plugins/session-sync.js` exists; restart opencode — if it was never installed, this machine skipped `roe setup` |
| New machine, no projects yet | run `roe new <name>` or see what's already synced: `roe projects` then `roe clone <name>` |
| What does this project need? | `roe status` (push / pull / upgrade / all caught up) |
| Project's seeded files have drifted (status says `seed: drifted`) | `roe upgrade` refills the missing/old seed files, keeping the model and your content |
| Toolkit is behind (status says `toolkit: … run: roe update`) | `roe update`, then `roe status` again — projects may now need `roe upgrade` |
| Which files actually sync here / stop one syncing | `roe track` — three panes (tracked / untracked-but-synced / ignored); ignore/unignore edits only the roe-owned `.gitignore` block |
| Back up this machine's chat history / recover another machine's | `roe history backup` — archives into `opencode-history/<host>.jsonl.gz` in the repo; `roe history list` / `roe history show <id>` read any machine's archive (`/sync` reminds you if it's missing or >7 days old) |