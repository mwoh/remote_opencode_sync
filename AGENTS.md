# AGENTS.md — standing instructions for this repository

> You are working in **remote_opencode_sync** (`github.com/mwoh/remote_opencode_sync`),
> the cross-device opencode sync toolkit. If you are taking over (a new session, a new
> agent), read `docs/agent-handoff.md` **first** — it is the operational state: current
> version, how to run the test suites, the release process, and every hard-won gotcha.
> Then `PLAN.md` (design/architecture), `README.md` (user docs), and the other docs under
> `docs/` as needed.

## 1. Session start — orient before touching anything
- Confirm git state is sane: `git status`. Leave pre-existing uncommitted changes alone
  and say so.
- Read `docs/agent-handoff.md` (the takeover guide) and `CONTINUE.md` (the running
  handoff) before any work. State what the last session did and what the NEXT STEPS are
  before proceeding.
- This repo carries the `.opencode/toolkit` marker, so the session-sync plugin runs
  here too: it pulls/rebase on session start, snapshots dirty work as `wip:` on idle,
  and injects CONTINUE.md + the session log into compaction. If the plugin isn't
  installed, do the `git pull --rebase` yourself.
- Finish each task as a coherent change set (below) — commit + push, and keep the
  LAST SESSION block in `CONTINUE.md` fresh so any machine can continue.

## The #1 rule: never leave anything stale

**Any change ships as one coherent change set.** When you modify code (or templates,
plugins, the `roe` front-end), update in the SAME change whatever is affected:

- the code / template / plugin itself
- the tests that cover it (`tests/*`) — run them, keep them green
- `README.md` — command tables, layout listing, pinned install URL, behavior claims
- `PLAN.md` — component table, workflow descriptions, roadmap checkboxes
- `docs/scripts-reference.md` — options, dispatch wiring, env vars
- `docs/daily-workflow.md` and `docs/machine-setup.md` — only when behavior touches the
  flows they describe (check, don't assume)
- `docs/agent-handoff.md` — Current state, release history, test counts, gotchas
- **release notes / SHA** — when a release is cut

**Test-count rule:** if a suite's check count changes, update the printed claims of that
count everywhere it appears (README, PLAN, agent-handoff, release notes) in the same
change. If a suite gains/loses checks, the counts elsewhere go stale — that's a bug.

**Release doc-sync:** a version bump updates, together: the README pinned install URL,
the PLAN roadmap checkboxes, agent-handoff's Release history + Current state, and the gh
release notes (with the bootstrap SHA block). Never tag/release before running all three
suites (`bash tests/features.sh`, `bash tests/model-features.sh`,
`node tests/plugin-test.mjs`) plus `bash -n`.

## Conventions (see docs/agent-handoff.md §5 for the full list)

- **Commit, push, tag, and release as part of finishing the work — don't wait to be asked.**
  Every coherent change set ships as a tagged release: label it `(vX.Y.Z)`, follow
  `docs/agent-handoff.md` §4 end to end (all suites green, doc-sync, tag, SHA verify,
  notes), push the tag + `main`, and call the release out in the summary.
- Commit style: `type: <lowercase subject> (vX.Y.Z)` with `feat:`/`fix:`/`docs:`/`chore:`.
- Runtime code stays **dependency-light bash** — no `jq`, `python`, or `node` in shipped
  scripts (`gh --template` for JSON, awk/sed for text). Python MAY appear only inside
  test assertions.
- Don't break the detection markers: `.opencode/toolkit` containing `remote_opencode_sync`,
  the `## 1. Session start` rules header, and the `.gitignore` scaffold marker — the
  plugin, `projects.sh`, `desync.sh`, and `new-project.sh` all key off them.
- New docs go under `docs/` and MUST be registered in the `README.md` layout listing.
- Keep this file current too: if a rule here changes, say so explicitly.