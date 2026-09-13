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
| `PLAN.md` | This document |
| `templates/AGENTS.md.tpl` | The base prompt / workflow rules (Layer 1) |
| `templates/workflow-rules.md.tpl` | Rules-only block appended to existing `AGENTS.md` on adopt |
| `templates/.gitignore.append.tpl` | Ignore patterns appended to existing `.gitignore` on adopt |
| `templates/CONTINUE.md.tpl` | Handoff log starter with `LAST SESSION` block |
| `templates/opencode.jsonc.tpl` | Project config: `/resume`, `/handoff`, `/sync` commands |
| `templates/.gitignore.tpl` | Excludes deps, builds, env files, machine-local state |
| `templates/.env.example.tpl` | Reference for secret env vars (real `.env` is gitignored) |
| `plugins/session-sync.js` | Global zero-touch sync plugin (Layer 2); acts only in projects carrying the `.opencode/toolkit` marker (opt-out: `.opencode/state/no-session-sync`) |
| `scripts/bootstrap.sh` | One-liner install / update entry point (curl pipe) |
| `scripts/update.sh` | Update an already-installed toolkit |
| `scripts/new-project.sh` | Create a repo from scratch, or adopt an existing directory (`--existing`, `--resolve`, `--scan`, `--force`) |
| `scripts/setup-machine.sh` | Lazy one-time machine setup (incl. git identity + SSH key); writes the uninstall manifest used by `scripts/uninstall.sh` |
| `scripts/uninstall.sh` | Reverse of setup: removes only what the install created (per the manifest), per-tool/auth/ssh questionnaire, `--dry-run`/`--yes` |
| `scripts/lib.sh` | Shared helpers (placeholder relink, package install/remove, uninstall manifest) |
| `docs/machine-setup.md` | First-step checklist for a new machine (what the script does) |
| `docs/daily-workflow.md` | Reference: everyday flows, edge cases, advanced options |

## Workflows

### New project (run once, from any machine)
1. `scripts/new-project.sh <name> [--setup]`
   - Pre-flight checks `git`, `gh`, and `gh auth`; fails fast with guidance
     (points to `docs/machine-setup.md` / `scripts/setup-machine.sh`), or with
     `--setup` hands off to the setup script automatically.
   - `gh repo create <name> --private --clone`, seeds the templates, first commit + push.
2. `cd <name> && opencode` — plugin pulls (nothing to pull on day one), base prompt
   orients you.

### Adopt an existing directory (run once)
`scripts/new-project.sh --existing <dir> [--name <repo>] [--resolve …] [--no-scan]
[--force]` — preserves history, seeds/workflow rules without clobbering (append by
default), drops a FIRST STEP for the first session's scan-and-orient pass, commits +
pushes.

### Project updates (run from any machine)
`~/.local/share/remote_opencode_sync/scripts/update.sh` (or re-run the bootstrap curl) —
pull toolkit, re-run setup (idempotent), re-link placeholders, restart opencode.

### New/unseen machine
- **Stage 1 (once per machine):** `docs/machine-setup.md` or the lazy
  `scripts/setup-machine.sh` — install tools, `gh auth`, SSH key, install the sync
  plugin globally.
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
- [x] Released v1.0.0 / v1.1.0 / v1.2.0 / v1.3.0 (adopt-existing, update.sh, uninstall.sh, plugin project-gating) with installer SHA pins
- [ ] Run `scripts/setup-machine.sh` (or checklist) on each machine
- [ ] `scripts/new-project.sh` a real project and verify cross-machine resume