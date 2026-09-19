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
| `scripts/pull.sh` | `roe pull` — fetch + clean `pull --rebase` with stash/pop (the plugin's session-start ritual, exposed manually) |
| `scripts/push.sh` | `roe push` — push committed state; refuses a non-fast-forward (never clobbers remote work) |
| `scripts/upgrade.sh` | `roe upgrade` — non-destructive refresh of a project's seed files to the current toolkit (marker, fallback commands preserving the pinned model, missing rules/ignore blocks, `session-logs/`); pulls first, commits + pushes the refresh, or "nothing to update" |
| `scripts/track.sh` | `roe track` — see/change what a project syncs. Because the plugin's wip snapshot does `git add -A`, `.gitignore` is the true sync boundary; this edits only the `# --- added by remote_opencode_sync ---` block. `--list` (tracked / untracked-but-synced / ignored), `--ignore` (append pattern, + `git rm --cached` if tracked), `--unignore` (remove pattern, + `git add`); project resolved by `project_root` walk-up; escaping paths refused |
| `scripts/track_tui.py` | curses TUI for `roe track` — python3 **standard-library only** (`curses`), a thin presentation layer that shells back to `track.sh` flags (the single source of truth); falls back to the text report when python3/`curses` is unavailable or not a terminal |
| `scripts/setup-machine.sh` | Lazy one-time machine setup (incl. git identity + SSH key); links `roe` into `~/.local/bin` + PATH; writes the uninstall manifest used by `scripts/uninstall.sh` |
| `scripts/uninstall.sh` | Reverse of setup: removes only what the install created (per the manifest), per-tool/auth/ssh questionnaire, `--dry-run`/`--yes` |
| `scripts/lib.sh` | Shared helpers (placeholder relink, package install/remove, uninstall manifest, model pin: `model_resolve`/`model_set`/`model_get`, project seed detection: `project_has_marker`/`project_desynced`/`project_commands_current`/`project_rules_current`/`project_gitignore_current`/`project_seed_stale`/`project_root`, comment-aware JSONC block injector: `jsonc_inject_block`) |
| `docs/machine-setup.md` | First-step checklist for a new machine (what the script does) |
| `docs/daily-workflow.md` | Reference: everyday flows, edge cases, advanced options |
| `docs/scripts-reference.md` | Reference: every script, its options, and how `roe` wires through |
| `docs/agent-handoff.md` | Takeover guide: current state, how to run the tests, release process, gotchas |
| `tests/` | Vendored verification harnesses: `features.sh` (145 sandbox e2e checks), `model-features.sh` (28 model-helper checks), `plugin-test.mjs` (15 plugin checks), `shims/gh` (fake GitHub for the sandbox) |

## Workflows

### New project (run once, from any machine)
1. `scripts/new-project.sh <name> [--setup] [--model <id>]`
   - Pre-flight checks `git`, `gh`, and `gh auth`; fails fast with guidance
     (points to `docs/machine-setup.md` / `scripts/setup-machine.sh`), or with
     `--setup` hands off to the setup script automatically.
   - Pins the opencode model in `opencode.jsonc` (from `--model` > `$MODEL_PIN` >
     global opencode config > prompt; line omitted if unresolved).
   - `gh repo create <name> --private --clone`, seeds the templates, first commit + push.
2. `cd <name> && opencode` — plugin pulls (nothing to pull on day one), base prompt
   orients you.

### Adopt an existing directory (run once)
`scripts/new-project.sh --existing <dir> [--name <repo>] [--resolve …] [--no-scan]
[--force] [--model <id>]` — preserves history, seeds/workflow rules without clobbering
(append by default), drops a FIRST STEP for the first session's scan-and-orient pass,
pins the model in `opencode.jsonc` (an existing model is respected and kept), commits +
pushes. Adopt hardening: warns when the pre-existing tree is dirty (those changes ride
into the import commit), names the replaced `origin` under `--force`, pushes annotated
tags (`--follow-tags`), and after the push hints when the pushed branch isn't the
remote's default.

### Project updates (run from any machine)
`roe update` (or re-run the bootstrap curl, or
`~/.local/share/remote_opencode_sync/scripts/update.sh`) — pull toolkit, re-run setup
(idempotent), re-link placeholders, restart opencode.

### Project sync state + manual sync (run from any roe project)
`roe status` is the read-only counterpart to `git status` for the sync itself: it fetches
and reports whether the project needs a push (`roe push`), a pull (`roe pull`), conflict
resolution (diverged — `git pull --rebase`), a commit, a `roe upgrade` (seed drift), a
`roe update` (toolkit behind), or is "all caught up". `roe pull`/`roe push` are the manual
in/out halves (optional — the plugin does this daily); `roe upgrade` refreshes an existing
project's seed files to the current toolkit, preserving the pinned model and never
overwriting user content.

### Sync scope (`roe track`)
Because the idle `wip:` snapshot commits everything git would add, what a project syncs is
decided by `.gitignore`. `roe track` surfaces that decision and edits only the
`remote_opencode_sync`-managed block: keep a file syncing (default — everything not
ignored), stop it (`--ignore`, appending the pattern and `git rm --cached` when tracked),
or let it back in (`--unignore`, removing the pattern and re-adding). Works from any
subdirectory via the `project_root` walk-up; paths that escape the project root are
refused. The interactive TUI (`scripts/track_tui.py`) is python3 stdlib `curses` only.

### New/unseen machine
- **Stage 1 (once per machine):** `docs/machine-setup.md` or the lazy
  `roe setup` (`scripts/setup-machine.sh`) — install tools, `gh auth`, SSH key, install
  the sync plugin globally, and link the `roe` command.
- **Stage 2 (once per project):** `gh repo clone <name>` → `cd <name>` → install deps
  (never synced; each machine installs its own) → `opencode`. Everything from here is
  automatic.

### Daily
Start: `cd <project> && opencode`. Orient, work, close the laptop. State is pushed
continuously by the rules (Layer 1) and the idle hook (Layer 2). Switch machines and
repeat — `/resume`/`/handoff` are never required.

## Edge cases & the only manual moments
- **One-time machine setup** — inherently manual (auth, SSH keys).
- **Merge conflicts** — `git pull --rebase` can fail; the plugin logs it and you resolve
  once. Avoided by the "one machine actively works at a time" rule.
- **Work outside opencode** (raw terminal/editor edits) — no session events fire, so sync
  happens at the next session start/end instead of in real time. Still safe.
- **Concurrent machines** — supported by git, but conflicts are likely; not recommended.

## Security

- Private GitHub repos; never commit secrets. Env files are gitignored;
  `.env.example` is committed for reference.
- The plugin only ever runs `git`/filesystem commands — no network except git fetch/push.

## Advanced option (documented, deferred)

**opencode server mode** — run opencode server on the powerful desktop and drive the same
live session from the light laptop via web/IDE. No sync needed for that session at all.
Not primary here since you typically run one machine at a time; details in
`docs/daily-workflow.md`.

## Roadmap / status

- [x] PLAN, templates, plugin, scripts, docs written
- [x] `git init` + first commit of this toolkit repo
- [x] Create the GitHub repo for the toolkit and push
- [x] Adopt-existing mode + update.sh (v1.1.0) implemented and dry-run tested
- [x] Released v1.0.0 / v1.1.0 / v1.2.0 / v1.3.0 / v1.3.1 / v1.4.0 (adopt-existing, update.sh, uninstall.sh, plugin project-gating, per-session debounce, `roe` command) with installer SHA pins
- [x] Released v1.5.0 (per-project model pinning: `--model` / `$MODEL_PIN` / global config default, `roe model`, adopt respect-existing; docs audit + README rebrand)
- [x] Released v1.5.1 (fix seeded `prompt`→`template` schema break; migrate the adopted project; migration note in docs)
- [x] Released v1.5.2 (resumable `new`/`adopt`; `roe desync`/`roe resync`; `roe projects`/`roe clone`; plugin silent in non-toolkit projects)
- [x] Released v1.5.3 (fix `model_set` injection comma vs trailing `//` comments, caught by the rebuilt 28-check model regression)
- [x] Vendored the verification harnesses into `tests/` + added the takeover guide (`docs/agent-handoff.md`) and standing session instructions (`AGENTS.md`; the never-leave-anything-stale mandate)
- [x] Released v1.5.4 (vendored test harnesses + takeover guide + `AGENTS.md` standing instructions; adopt hardening — dirty-tree warning, origin-repoint notice, branch-vs-remote-default hint, `--follow-tags`; always-release cadence rule — features suite 61 → 71 checks, all green)
- [x] Released v1.5.5 (the toolkit repo self-hosts its own workflow: `.opencode/toolkit` marker, `opencode.jsonc`, `CONTINUE.md`, `session-logs/`, `.gitignore`, `## 1. Session start` rules header — clone anywhere → `roe setup` → `opencode` = full handoff; `tests/features.sh` §I guards the self-host markers — features suite 71 → 75 checks, all green)
- [x] Released v1.5.6 (`roe version` reports installed + latest release via git tags — pure bash/awk, offline-graceful, sandbox-tested against a fake origin; features suite 75 → 79 checks, all green)
- [x] Released v1.5.7 (`roe status`/`roe pull`/`roe push`/`roe upgrade` — the sync-state advisory + manual in/out halves + non-destructive project seed refresh; shared project-seed detection helpers in `lib.sh`; features suite 79 → 115 checks, all green)
- [x] Released v1.5.8 (`roe track` — see and change what a project syncs: tracked/untracked/ignored via the roe-owned `.gitignore` block, `--list`/`--ignore`/`--unignore` flags + a curses TUI (`scripts/track_tui.py`, python3 standard library only), `project_root` walk-up in `lib.sh`, escape guard; features suite 115 → 145 checks (§L), all green)
- [ ] Run `roe setup` (scripts/setup-machine.sh) on each machine
- [ ] `roe new` a real project and verify cross-machine resume