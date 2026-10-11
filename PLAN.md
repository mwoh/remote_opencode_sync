# Cross-Device OpenCode Sync Toolkit — PLAN

## Goal

Work with opencode on whichever machine fits the task — light laptop for writing,
planning, and docs; desktop/heavy laptop for compiling and heavy lifting — and pick up
exactly where you left off on the next machine, with **zero manual sync steps**.

## Design principle

**Git is the single source of truth for both code and progress.**

- Code, handoff notes (`CONTINUE.md`), and a lightweight running session log
  (`session-logs/`) all live in the repo and are continuously committed + pushed.
- Raw opencode conversation history stays on each machine's local SQLite; what travels
  between machines is the running summary in `CONTINUE.md` + `session-logs/` + git
  history. That is enough to fully re-orient.

```
               ┌─────────────────┐        ┌──────────────────┐
  LIGHT LAPTOP │                 │        │ DESKTOP / HEAVY  │
  (plan/doc)   │   GitHub        │        │  LAPTOP (build)  │
               │  private repo   │        │                  │
  opencode ─┐  │  (one per       │  ──┐   │    opencode   ─┐
            └▶ │   project)      │◀──┴──▶│                │
  git pull/push │  pull + push   │        │   git pull/push│
               └─────────────────┘        └──────────────────┘
```

## Two-layer sync model

Layer 1 and Layer 2 write to the same git history, so nothing is lost and neither
interferes with the other.

### Layer 1 — base prompt rules (primary, authoritative)
The `AGENTS.md` template baked into every project. Meaningful commits after each task,
continuous `CONTINUE.md` + `session-logs/` maintenance, END markers, auto-reconcile of
abandoned sessions, machine-capability rules. This is "everything as before" — fully
preserved and untouched by the plugin.

### Layer 2 — session-sync plugin (additive safety net)
A single global opencode plugin installed once per machine at
`~/.config/opencode/plugins/session-sync.js`. Adds zero-touch behavior on top:

- `session.created` → git plumbing: fetch, safe stash/pop, `pull --rebase`, push if
  local-ahead and clean. (Replaces manual `/resume`.)
- `session.idle` (debounced ~2 min) → if the tree is dirty, auto-commit `wip: <host>
  <stamp>` and push, plus a line in the session log. (Replaces manual `/handoff`
  safety gap.)
- `experimental.session.compacting` → inject `CONTINUE.md` + session log into the
  compaction prompt so continuity survives context compression.

`/resume` and `/handoff` still exist as manual fallback commands for edge cases.

Uninstall support: `setup-machine.sh` writes a manifest
(`~/.local/state/remote_opencode_sync/uninstall.conf`, outside the repo) recording what
it created; `scripts/uninstall.sh` consumes it to remove only those things, with
per-category/per-tool opt-in and `--dry-run`. Project files are never touched.

## Components

| Path | Purpose |
| --- | --- |
| `AGENTS.md` | Standing session instructions: the never-leave-anything-stale mandate, conventions, test/release pointers (+ the session-start rules header — the repo dogfoods its own rules) |
| `PLAN.md` | This document |
| Repo-root scaffold | The toolkit repo is itself a toolkit project: `.opencode/toolkit` marker, `opencode.jsonc` (pinned model + `/resume`/`/handoff`/`/sync`), `CONTINUE.md` (running handoff), `session-logs/`, `.gitignore` — a fresh clone + `roe setup` + `opencode` is a full handoff on any machine |
| `templates/AGENTS.md.tpl` | The base prompt / workflow rules (Layer 1) |
| `templates/workflow-rules.md.tpl` | Rules-only block appended to existing `AGENTS.md` on adopt |
| `templates/.gitignore.append.tpl` | Ignore patterns appended to existing `.gitignore` on adopt |
| `templates/CONTINUE.md.tpl` | Handoff log starter with `LAST SESSION` block |
| `templates/opencode.jsonc.tpl` | Project config: `/resume`, `/handoff`, `/sync` commands + pinned `model` (`@@MODEL@@`, substituted at seed time) |
| `templates/.gitignore.tpl` | Excludes deps, builds, env files, machine-local state |
| `templates/.env.example.tpl` | Reference for secret env vars (real `.env` is gitignored) |
| `plugins/session-sync.js` | Global zero-touch sync plugin (Layer 2); acts only in projects carrying the `.opencode/toolkit` marker (opt-out: `.opencode/state/no-session-sync`) |
| `scripts/bootstrap.sh` | One-liner install / update entry point (curl pipe) |
| `bin/roe` | The `roe` command front-end: a single short command dispatching every script (`update`/`setup`/`new`/`adopt`/`model`/`status`/`pull`/`push`/`upgrade`/`uninstall`/`version`); symlinked into `~/.local/bin` by setup, resolved via `readlink -f` so it follows updates. `roe version` reports the installed copy vs the latest release tag on its origin (pure `git ls-remote` + awk; no auth/network-beyond-git) |
| `scripts/update.sh` | Update an already-installed toolkit |
| `scripts/new-project.sh` | Create a repo from scratch, or adopt an existing directory (`--existing`, `--resolve`, `--scan`, `--force`, `--model`) |
| `scripts/status.sh` | `roe status` — read-only advisory: is a directory a valid roe project, and what does it need (push/pull/diverged/dirty/desync/seed-drift/toolkit-update)? Exit 0 current · 1 not a roe project · 2 action needed |
| `scripts/projects.sh` | `roe projects` — list your GitHub repos carrying the marker, annotating each with whether/where a local copy exists under the scan root (cwd, a project's parent when run inside one, or `--dir`) and its state (`clean`/`dirty N`/`ahead N`/`behind N`/`diverged`/`desynced`), plus a section for local roe projects not in the GitHub list; local copies matched by git origin, `git fetch`ed by default (`--no-fetch` opts out). `roe clone` clones a verified repo |
| `scripts/pull.sh` | `roe pull` — fetch + clean `pull --rebase` with stash/pop (the plugin's session-start ritual, exposed manually) |
| `scripts/push.sh` | `roe push` — push committed state; refuses a non-fast-forward (never clobbers remote work) |
| `scripts/upgrade.sh` | `roe upgrade` — non-destructive refresh of a project's seed files to the current toolkit (marker, fallback commands preserving the pinned model, missing rules/ignore blocks, `session-logs/`); pulls first, commits + pushes the refresh, or "nothing to update" |
| `scripts/track.sh` | `roe track` — see/change what a project syncs. Because the plugin's wip snapshot does `git add -A`, `.gitignore` is the true sync boundary; this edits only the `# --- added by remote_opencode_sync ---` block. `--list` (tracked / untracked-but-synced / ignored), `--ignore` (append pattern, + `git rm --cached` if tracked), `--unignore` (remove pattern, + `git add`); project resolved by `project_root` walk-up; escaping paths refused |
| `scripts/track_tui.py` | curses TUI for `roe track` — python3 **standard-library only** (`curses`), a thin presentation layer that shells back to `track.sh` flags (the single source of truth); falls back to the text report when python3/`curses` is unavailable or not a terminal |
| `scripts/history.sh` | `roe history` — `backup`/`list`/`show` this machine's opencode session history for a project. `backup` exports the project's sessions from opencode's central db (read-only) to `opencode-history/<host>/<session-id>.jsonl.gz` (one file per session) inside the repo, so the archive syncs to every machine; `list`/`show` render an archived machine's sessions/transcripts. Project resolved by `project_root` walk-up; non-roe dirs refused |
| `scripts/history.py` | read-only opencode-db exporter/reader behind `roe history` — python3 **standard-library only** (`sqlite3`/`json`/`gzip`), opens the db `mode=ro`, matches sessions to the project (worktree/directory), writes one gzip JSONL file per session and skips unchanged sessions (content hash), prunes deleted ones, and migrates any pre-v1.8.0 rolled-up archive; `show` renders markdown transcripts. All state mutation stays in bash |
| `scripts/setup-machine.sh` | Lazy one-time machine setup (incl. git identity + SSH key); links `roe` into `~/.local/bin` + PATH; writes the uninstall manifest used by `scripts/uninstall.sh` |
| `scripts/uninstall.sh` | Reverse of setup: removes only what the install created (per the manifest), per-tool/auth/ssh questionnaire, `--dry-run`/`--yes` |
| `scripts/lib.sh` | Shared helpers (placeholder relink, package install/remove, uninstall manifest, model pin: `model_resolve`/`model_set`/`model_get`, project seed detection: `project_has_marker`/`project_desynced`/`project_commands_current`/`project_rules_current`/`project_gitignore_current`/`project_seed_stale`/`project_root`, comment-aware JSONC block injector: `jsonc_inject_block`) |
| `docs/machine-setup.md` | First-step checklist for a new machine (what the script does) |
| `docs/daily-workflow.md` | Reference: everyday flows, edge cases, advanced options |
| `docs/scripts-reference.md` | Reference: every script, its options, and how `roe` wires through |
| `docs/agent-handoff.md` | Takeover guide: current state, how to run the tests, release process, gotchas |
| `tests/` | Vendored verification harnesses: `features.sh` (205 sandbox e2e checks), `model-features.sh` (28 model-helper checks), `plugin-test.mjs` (15 plugin checks), `shims/gh` (fake GitHub for the sandbox) |

## Distribution — two repos (since v1.7.0)

`roe` ships as a **generated public distribution**, developed in a **private source repo**.

| Repo | Visibility | Role |
| --- | --- | --- |
| `mwoh/remote_opencode_sync` | public | The distribution. Installed by `bootstrap.sh` (same URL, tags, and pins as always). Contains only what makes `roe` *run*. |
| `mwoh/remote_opencode_sync-dev` | private | The source of truth. Full history, all development, all tests, plus this project's own `CONTINUE.md`, `session-logs/`, and committed `opencode-history/` archives. Changes are made and released here. |

This split exists because the archives `roe history` writes (`opencode-history/<host>/…`) are
the **full raw transcript** — they must never land in a public repo, but they *should* travel
between a private project's machines. Before v1.7.0 this repo was public and therefore had to
gitignore its own archive; the private dev repo removes that exception. Because `history.py`
matches sessions by project worktree, the private side must be a full clone of the project —
which is exactly what the dev repo is.

**Public manifest** (everything else is dev-only): `LICENSE`, `README.md`, `PLAN.md`,
`bin/`, `scripts/` (except `publish.sh`), `templates/`, `plugins/session-sync.js`, and
`docs/{machine-setup,daily-workflow,scripts-reference}.md`.

**Dev-only**: `AGENTS.md`, `CONTINUE.md`, `session-logs/`, `opencode-history/`, `tests/`,
`docs/agent-handoff.md`, `.opencode/`, `opencode.jsonc`, the root `.gitignore`,
