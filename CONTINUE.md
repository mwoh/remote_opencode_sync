# remote_opencode_sync — Continuation Log

_This file is the cross-device memory. Read it first thing each session, update it as you
work. It gets committed constantly, so keep it accurate and terse. Another machine will
read ONLY this plus commit history to re-orient._

## LAST SESSION

- **Machine:** squirtle (this machine)
- **Date:** 2026-09-19
- **Summary:** Shipped **v1.6.0** (feature), and earlier the same session **v1.5.10**
  (fix) and **v1.5.9** (`roe history`).
  - **v1.6.0 — `roe projects` local presence + state:** each listed repo is now annotated
    with whether/where it exists locally and that copy's state. `LOCAL` column =
    `-` / `here` / `./dir` plus `clean` / `dirty N` / `ahead N` / `behind N` /
    `diverged (A ahead, B behind)` / `desynced · …` / `unknown (no upstream)`. Scan root =
    `--dir`, else cwd, else **a project's parent when run from inside one** (so siblings
    are found); only the root + immediate marker-bearing children. Local copies matched by
    **git origin basename** (`x.git`→`x`, dir-name fallback). Each local copy is
    `git fetch`ed **by default** (accurate; `--no-fetch` opts out, renders `offline?` on
    failure); remote repo scan stays cached. A trailing **"other local roe projects"**
    section surfaces local projects not in the GitHub list (unpublished/other owner/offline).
    Portability: collected into a temp TSV — **no associative arrays** (macOS bash 3.2).
    features 177 → 186 (§F F3: clean/dirty/local-only/parent-heuristic/`--dir`/`--no-fetch`).
  - **v1.5.10 — fix `roe projects`:** it passed `--owner` to `gh repo list`, which takes the
    owner **positionally**, so every scan aborted and blamed auth. Fixed; scan failures now
    print the real `gh:` error and only suggest `roe setup` when `gh auth status` fails.
    `tests/shims/gh` now mirrors real flag parsing (rejects `--owner`), plus a §F guard.
  - **v1.5.9 — `roe history`:** per-(project × machine) session-history backups.
    `scripts/history.py` (python3 **stdlib only**: `sqlite3`/`json`/`gzip`; second AGENTS.md
    carve-out) reads opencode's db **read-only** and exports this project's sessions to a
    rolling `opencode-history/<host>.jsonl.gz` in the repo; `history.sh` wraps
    `backup`/`list`/`show`. `/handoff` backs up, `/sync` warns when missing/>7d. Recovery is
    read/replay (no db-merge API). **Public-repo safety:** this repo is public, so
    `opencode-history/` is gitignored here (`roe track --ignore`); `backup` prints a
    "will NOT sync" note when ignored (M9).
  - Ran after an incident: a prior session/agent advised `rm -rf ~/.local/share/opencode`,
    which wiped this machine's opencode chat history (no timeshift/trash). Nothing in the
    toolkit/plugin/repo depended on that dir — the loss was history only.
  - All suites green: features **186**, model 28, plugin 15, `bash -n` + `py_compile` clean.
  - Doc-sync done for all three: README (pinned URL, command tables, projects section,
    history section, layout), PLAN.md (component rows + roadmap), scripts-reference,
    daily-workflow, agent-handoff (current state, release history, counts, §2/§6 gotchas),
    session logs.
- **NEXT STEPS:**
  - [ ] Run `roe setup` (scripts/setup-machine.sh) on every machine — installs the global
        session-sync plugin + git identity and links `roe`.
  - [ ] Run `roe history backup` on the other machines **inside your private projects** so
        each machine's history is archived in that project's repo. (This public toolkit repo
        gitignores its own archive, so this machine's dev history here stays local-only.)
  - [ ] `roe new <name>` a real project and verify a full cross-machine resume end to end;
        use `roe track` on it to confirm the sync scope is what's expected.
  - [ ] opencode v2: intentionally deferred — do not port the plugin until the v2 plugin
        API stops changing (beta).

## Status

The toolkit is complete for v1.6.0: workflow scripts + plugin + templates, ten releases,
vendored verification suites (features 186 / model 28 / plugin 15), ops/takeover docs,
and this repo is itself a toolkit project. Working tree clean at release.

## Open decisions

- **opencode v2 migration** — deferred until the beta plugin/server APIs stabilize; the
  only mandatory rewrite would be `plugins/session-sync.js` (V1 plugin API is dead in v2).
- **New-machine onboarding for this repo** — `git clone git@github.com:mwoh/remote_opencode_sync.git` → `roe setup` → `opencode` (AGENTS.md points at `docs/agent-handoff.md`, then to this file).

## Session log

- 2026-09-19 — v1.5.4 released (adopt hardening + always-release cadence); v1.5.5 released (toolkit repo self-hosts its own workflow — clone anywhere → `roe setup` → `opencode` = full handoff; §I self-host tests, features 71 → 75); v1.5.6 released (`roe version` reports installed + latest release — §J, features 75 → 79); v1.5.7 released (`roe status`/`roe pull`/`roe push`/`roe upgrade` — §K e2e, seed-predicate helpers in lib.sh, comment-aware command-block injector; features 79 → 115); v1.5.8 released (`roe track` — sync-scope list/ignore/unignore + curses TUI, `project_root` walk-up in lib.sh, roe-block-only `.gitignore` edits, escape guard; §L e2e + py_compile, features 115 → 145); v1.5.9 released (`roe history` — per-machine session-history backups from a read-only opencode-db export into `opencode-history/<host>.jsonl.gz`, `/handoff` backup + `/sync` stale nag, second python-stdlib carve-out; §M e2e, features 145 → 176); v1.5.10 released (fix `roe projects` — `gh repo list` owner is positional, not `--owner`; honest scan errors; `gh` shim flag-fidelity guard; features 176 → 177); v1.6.0 released (`roe projects` local presence + sync state — `LOCAL` column, scan root = `--dir`/cwd/project's parent, local-only section, per-copy `git fetch`, `--no-fetch`; §F F3, features 177 → 186).
