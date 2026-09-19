# remote_opencode_sync — Continuation Log

_This file is the cross-device memory. Read it first thing each session, update it as you
work. It gets committed constantly, so keep it accurate and terse. Another machine will
read ONLY this plus commit history to re-orient._

## LAST SESSION

- **Machine:** squirtle (this machine)
- **Date:** 2026-09-19
- **Summary:** Shipped v1.5.8 — `roe track`, what a project actually syncs:
  - Because the plugin's idle `wip:` snapshot does `git add -A`, `.gitignore` is the true
    sync boundary. `roe track [dir]` (scripts/track.sh) shows three states — tracked /
    untracked-but-synced / ignored — and moves files between them: `--list` prints the
    plain lists; `--ignore <path>…` appends the pattern to the roe `.gitignore` block
    (+ `git rm --cached` when tracked, file stays on disk); `--unignore <path>…` removes
    the rule (+ `git add`). **Only** the `# --- added by remote_opencode_sync ---` block
    is ever edited; user rules elsewhere are reported and `--unignore` refuses them (exit 1).
  - `roe track` with no flags runs `scripts/track_tui.py` — a curses TUI (python3
    **standard-library only**, AGENTS.md carve-out; presentation-only, shells back to
    `track.sh`). Three panes, Tab/1-2-3, arrows/jk, Enter/Space toggle, r refresh, ? help,
    q quit; header `project: <basename> · root: <abs>`.
  - Project resolution walks up (`project_root` added to lib.sh) so it works from any
    subdirectory; root-relative paths escaping the root are refused (exit 1); idempotent
    re-ignore. Cross-machine caveat: rules propagate via push, gitignore never un-tracks
    historical files on other machines by itself.
  - `bin/roe` gained `track` dispatch; tests §L (10 checks: walk-up, three states,
    dispatch + TTY fallback, ignore untracked/tracked, idempotent, unignore re-track,
    user-rule refusal, escape refusal, not-a-project) + `py_compile` check; features suite
    grew 115 → 145 checks (all green, plus model 28 / plugin 15 and clean `bash -n`);
    TUI pty smoke-test quit rc=0.
  - Doc-sync done: README (v1.5.8 pinned URL + track row + "What actually syncs" section),
    PLAN.md (component table + roadmap), scripts-reference (track section + dispatch +
    lib.sh helpers), daily-workflow (track row), agent-handoff (current state, release
    history, 145 counts, §3/§6 gotchas: python carve-out, roe-block-only, cross-machine
    caveat, walk-up).
- **NEXT STEPS:**
  - [ ] Run `roe setup` (scripts/setup-machine.sh) on every machine — installs the global
        session-sync plugin + git identity and links `roe`.
  - [ ] `roe new <name>` a real project and verify a full cross-machine resume end to end;
        use `roe track` on it to confirm the sync scope is what's expected.
  - [ ] Try `roe status` in a real project and on an older seeded project, and `roe upgrade`
        to bring it to the current seed (the first real-world upgrade sanity check).
  - [ ] opencode v2: intentionally deferred — do not port the plugin until the v2 plugin
        API stops changing (beta).

## Status

The toolkit is complete for v1.5.8: workflow scripts + plugin + templates, seven releases,
vendored verification suites (features 145 / model 28 / plugin 15), ops/takeover docs,
and this repo is itself a toolkit project. Working tree clean at release.

## Open decisions

- **opencode v2 migration** — deferred until the beta plugin/server APIs stabilize; the
  only mandatory rewrite would be `plugins/session-sync.js` (V1 plugin API is dead in v2).
- **New-machine onboarding for this repo** — `git clone git@github.com:mwoh/remote_opencode_sync.git` → `roe setup` → `opencode` (AGENTS.md points at `docs/agent-handoff.md`, then to this file).

## Session log

- 2026-09-19 — v1.5.4 released (adopt hardening + always-release cadence); v1.5.5 released (toolkit repo self-hosts its own workflow — clone anywhere → `roe setup` → `opencode` = full handoff; §I self-host tests, features 71 → 75); v1.5.6 released (`roe version` reports installed + latest release — §J, features 75 → 79); v1.5.7 released (`roe status`/`roe pull`/`roe push`/`roe upgrade` — §K e2e, seed-predicate helpers in lib.sh, comment-aware command-block injector; features 79 → 115); v1.5.8 released (`roe track` — sync-scope list/ignore/unignore + curses TUI, `project_root` walk-up in lib.sh, roe-block-only `.gitignore` edits, escape guard; §L e2e + py_compile, features 115 → 145).