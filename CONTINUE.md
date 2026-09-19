# remote_opencode_sync — Continuation Log

_This file is the cross-device memory. Read it first thing each session, update it as you
work. It gets committed constantly, so keep it accurate and terse. Another machine will
read ONLY this plus commit history to re-orient._

## LAST SESSION

- **Machine:** squirtle (this machine)
- **Date:** 2026-09-19
- **Summary:** Shipped v1.5.5 — made THIS repo a toolkit project (`.opencode/toolkit`
  marker, `opencode.jsonc` with pinned model + `/resume`/`/handoff`/`/sync`, `CONTINUE.md`,
  `session-logs/`, `.gitignore`, and the `## 1. Session start` rules header in `AGENTS.md`)
  so a fresh clone anywhere → `roe setup` → `opencode` is a full handoff. Then shipped
  v1.5.6 — `roe version` now reports the installed vs latest release (git tags, pure
  bash/awk, offline-graceful), with `tests/features.sh` §J + new `lib.sh` helpers
  (`ver_sort_max` / `ver_gt` / `toolkit_latest_ver`). Both fully doc-synced and released;
  features suite grew 71 → 75 → 79 checks (all green, plus model 28 / plugin 15 and a
  clean `bash -n`).
- **NEXT STEPS:**
  - [ ] Run `roe setup` (scripts/setup-machine.sh) on every machine — installs the global
        session-sync plugin + git identity and links `roe`.
  - [ ] `roe new <name>` a real project and verify a full cross-machine resume end to end.
  - [ ] opencode v2: intentionally deferred — do not port the plugin until the v2 plugin
        API stops changing (beta).

## Status

The toolkit is complete for v1.5.6: workflow scripts + plugin + templates, five releases,
vendored verification suites (features 79 / model 28 / plugin 15), ops/takeover docs, and
this repo is itself a toolkit project. Working tree clean at release.

## Open decisions

- **opencode v2 migration** — deferred until the beta plugin/server APIs stabilize; the
  only mandatory rewrite would be `plugins/session-sync.js` (V1 plugin API is dead in v2).
- **New-machine onboarding for this repo** — `git clone git@github.com:mwoh/remote_opencode_sync.git` → `roe setup` → `opencode` (AGENTS.md points at `docs/agent-handoff.md`, then to this file).

## Session log

- 2026-09-19 — v1.5.4 released (adopt hardening + always-release cadence); v1.5.5 released (toolkit repo self-hosts its own workflow — clone anywhere → `roe setup` → `opencode` = full handoff; §I self-host tests, features 71 → 75); v1.5.6 released (`roe version` reports installed + latest release — §J, features 75 → 79).