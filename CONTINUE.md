# remote_opencode_sync — Continuation Log

_This file is the cross-device memory. Read it first thing each session, update it as you
work. It gets committed constantly, so keep it accurate and terse. Another machine will
read ONLY this plus commit history to re-orient._

## LAST SESSION

- **Machine:** squirtle (this machine)
- **Date:** 2026-09-19
- **Summary:** Shipped v1.5.9 — `roe history`, per-(project × machine) session-history
  backups, after a real incident: a prior session/agent advised deleting
  `~/.local/share/opencode`, which wiped this machine's opencode chat history (only the
  live session survived; no timeshift/trash). Assessment: nothing in the toolkit/plugin/
  repo depends on that dir (`~/.config/opencode` plugin, `~/.local/state/opencode` state,
  and `~/.opencode/bin/opencode` all live elsewhere) — the loss was history only.
  - `scripts/history.py` (python3 **stdlib only**: `sqlite3`/`json`/`gzip`; second
    AGENTS.md carve-out) opens opencode's db **read-only** (`mode=ro`) and exports only
    **this project's** sessions (matched via `project.worktree` /
    `project_directory.directory` / `session.directory`) to a rolling
    `opencode-history/<host>.jsonl.gz` **inside the repo**, so normal sync carries every
    machine's history to every machine. `scripts/history.sh` wraps it: `backup` / `list` /
    `show <id>` (exact id or unique prefix, markdown transcript with `[tool: …]` markers),
    `project_root` walk-up, refuses non-roe dirs, `--db`/`OPENCODE_DB` + `--host` overrides.
  - Recovery is read/replay from the archive (opencode has no merge-db-back-in API) — the
    raw JSONL keeps full fidelity; documented honestly.
  - `/handoff` now runs `roe history backup` before its final commit; `/sync` **warns**
    when this machine's archive is missing or >7 days old (the option-B nag). `AGENTS.md`
    got the finish-each-task line + widened python carve-out.
  - **Public-repo safety:** this toolkit repo is **public**, and an archive is the full raw
    transcript — so `opencode-history/` is gitignored here (`roe track --ignore
    opencode-history`). `backup` runs `git check-ignore` and prints a "will NOT sync" note
    in that case (M9 test), so an ignored archive is never mistaken for a syncing one.
    Private `roe new` projects keep the archive tracked (the default).
  - `bin/roe` gained `history` dispatch; tests §M (backup, project scoping/exclusion,
    rolling idempotency, list/show/prefix, walk-up, non-roe/missing-db/missing-archive
    paths, roe dispatch) + `py_compile`; features suite grew 145 → 176 checks (all green,
    plus model 28 / plugin 15 and clean `bash -n`).
  - Doc-sync done: README (v1.5.9 pinned URL + history row/section + layout),
    PLAN.md (component table + workflow + roadmap), scripts-reference (history section +
    dispatch + exit codes), daily-workflow (row), agent-handoff (current state, release
    history, 176 counts, §2/§5/§6 gotchas).
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

The toolkit is complete for v1.5.9: workflow scripts + plugin + templates, eight releases,
vendored verification suites (features 176 / model 28 / plugin 15), ops/takeover docs,
and this repo is itself a toolkit project. Working tree clean at release.

## Open decisions

- **opencode v2 migration** — deferred until the beta plugin/server APIs stabilize; the
  only mandatory rewrite would be `plugins/session-sync.js` (V1 plugin API is dead in v2).
- **New-machine onboarding for this repo** — `git clone git@github.com:mwoh/remote_opencode_sync.git` → `roe setup` → `opencode` (AGENTS.md points at `docs/agent-handoff.md`, then to this file).

## Session log

- 2026-09-19 — v1.5.4 released (adopt hardening + always-release cadence); v1.5.5 released (toolkit repo self-hosts its own workflow — clone anywhere → `roe setup` → `opencode` = full handoff; §I self-host tests, features 71 → 75); v1.5.6 released (`roe version` reports installed + latest release — §J, features 75 → 79); v1.5.7 released (`roe status`/`roe pull`/`roe push`/`roe upgrade` — §K e2e, seed-predicate helpers in lib.sh, comment-aware command-block injector; features 79 → 115); v1.5.8 released (`roe track` — sync-scope list/ignore/unignore + curses TUI, `project_root` walk-up in lib.sh, roe-block-only `.gitignore` edits, escape guard; §L e2e + py_compile, features 115 → 145); v1.5.9 released (`roe history` — per-machine session-history backups from a read-only opencode-db export into `opencode-history/<host>.jsonl.gz`, `/handoff` backup + `/sync` stale nag, second python-stdlib carve-out; §M e2e, features 145 → 176).