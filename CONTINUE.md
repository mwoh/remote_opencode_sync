# remote_opencode_sync — Continuation Log

_This file is the cross-device memory. Read it first thing each session, update it as you
work. It gets committed constantly, so keep it accurate and terse. Another machine will
read ONLY this plus commit history to re-orient._

## LAST SESSION

- **Machine:** squirtle (this machine)
- **Date:** 2026-09-19
- **Summary:** Shipped v1.5.7 — manual sync commands for the roe front-end:
  - `roe status [dir]` (scripts/status.sh) — read-only advisory: is a valid roe project,
    and what does it need? Exit 0 = all caught up, 2 = action needed (ahead/behind/diver
    ged/dirty/desynced/seed-drift/toolkit-update), 1 = not a roe project. Fetch-only net.
  - `roe pull [dir]` / `roe push [dir]` (scripts/pull.sh, push.sh) — manual in/out halves
    of the sync; pull = fetch + clean `pull --rebase` with stash/pop (mirrors the plugin
    ritual), push refuses a non-fast-forward.
  - `roe upgrade [dir]` (scripts/upgrade.sh) — non-destructive per-project seed refresh:
    marker, fallback command block restored keeping the pinned model (comment-aware
    `jsonc_inject_block` in lib.sh extracts the block live from opencode.jsonc.tpl),
    missing AGENTS.md rules / .gitignore patterns, session-logs/; refuses a dirty tree
    and skips rules/ignore writes on desynced copies; commits + pushes or "nothing to
    update". Distinction: `roe update` = toolkit, `roe upgrade` = a project.
  - lib.sh gained the seed-detection predicate family (`project_has_marker` /
    `project_desynced` / `project_commands_current` / `project_rules_current` /
    `project_gitignore_current` / `project_seed_stale`); the rules marker accepts BOTH
    the `## 1. Session start` header and the append-block marker (also in
    new-project.sh `already_marked`), so status/upgrade never loop on append-block
    projects.
  - Tests §K (status/pull/push/upgrade e2e in the sandbox); features suite grew
    79 → 115 checks (all green, plus model 28 / plugin 15 and a clean `bash -n`); repo
    self-hosts the marker so this repo is a valid `roe status` target too.
- **NEXT STEPS:**
  - [ ] Run `roe setup` (scripts/setup-machine.sh) on every machine — installs the global
        session-sync plugin + git identity and links `roe`.
  - [ ] `roe new <name>` a real project and verify a full cross-machine resume end to end.
  - [ ] Try `roe status` in a real project and on an older seeded project, and `roe upgrade`
        to bring it to the current seed (the first real-world upgrade sanity check).
  - [ ] opencode v2: intentionally deferred — do not port the plugin until the v2 plugin
        API stops changing (beta).

## Status

The toolkit is complete for v1.5.7: workflow scripts + plugin + templates, six releases,
vendored verification suites (features 115 / model 28 / plugin 15), ops/takeover docs,
and this repo is itself a toolkit project. Working tree clean at release.

## Open decisions

- **opencode v2 migration** — deferred until the beta plugin/server APIs stabilize; the
  only mandatory rewrite would be `plugins/session-sync.js` (V1 plugin API is dead in v2).
- **New-machine onboarding for this repo** — `git clone git@github.com:mwoh/remote_opencode_sync.git` → `roe setup` → `opencode` (AGENTS.md points at `docs/agent-handoff.md`, then to this file).

## Session log

- 2026-09-19 — v1.5.4 released (adopt hardening + always-release cadence); v1.5.5 released (toolkit repo self-hosts its own workflow — clone anywhere → `roe setup` → `opencode` = full handoff; §I self-host tests, features 71 → 75); v1.5.6 released (`roe version` reports installed + latest release — §J, features 75 → 79); v1.5.7 released (`roe status`/`roe pull`/`roe push`/`roe upgrade` — §K e2e, seed-predicate helpers in lib.sh, comment-aware command-block injector; features 79 → 115).