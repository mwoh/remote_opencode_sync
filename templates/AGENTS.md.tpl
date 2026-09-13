# {{PROJECT_NAME}} — Workflow Rules (AGENTS.md)

This project lives in a Git repository shared across several of the user's machines
(laptops + a desktop). You run on one machine at a time, but the work may be continued
from any other machine at any moment. Treat the git remote as the source of truth for
BOTH the code and the progress. Follow these rules without being reminded.

## Project overview

_(What this project is, where it stands: purpose, entry points, key modules, build/test
commands, current state. Filled in by the first opencode session when adopting an
existing project, or by the user as the project evolves.)_

## 1. Session start — orient before touching anything
- Confirm git state is sane: `git status`. If there are pre-existing uncommitted changes
  you did not make, leave them alone and say so.
- Read `CONTINUE.md` before any work. State what the last session did and what the
  NEXT STEPS are before proceeding.
- Assume the pull/rebase/push plumbing has already run via the session-sync plugin
  (`session.created`). If the plugin is not present, do `git pull --rebase` yourself.

## 2. Auto-reconcile an abandoned session
If the most recent `session-logs/*.md` from ANOTHER machine is marked `IN PROGRESS` and
has no matching closed `LAST SESSION` block in `CONTINUE.md`, that session ended without
a clean handoff. Before starting work:
- Synthesize the handoff from that log plus recent commit messages: write a `LAST SESSION`
  entry into `CONTINUE.md`, mark the log file `END`, commit, push.
- Then tell the user what you reconstructed before moving on.

## 3. Commit + push after every completed task
- Whenever you finish a discrete unit of work (feature, fix, doc change, a decision that
  changed files) and the tree is in a reasonable state for the machine you are on:
  commit AND push immediately.
- Commit message format: `type(scope): short summary`
  (e.g. `feat(api): add search`, `fix(parser): handle empty input`, `docs: update CONTINUE.md`).
- Never leave unpushed commits at the end of a session.

## 4. Keep the tree clean
- The working tree must be clean at every session boundary. If you must pause mid-task,
  commit with a `wip:` message (or update `CONTINUE.md`) and push.
- The session-sync plugin also auto-commits leftovers as `wip: <host> <stamp>` when the
  user goes idle. Treat those as a backup only: write real, meaningful commits
  yourselves whenever possible so history stays readable.

## 5. Maintain CONTINUE.md continuously
- After each notable task, refresh `CONTINUE.md`: update Status, append decisions, keep
  NEXT STEPS current (check off done items, add the next one).
- Keep it terse and skimmable — another machine will read only this plus commit history.

## 6. Session log
- Each working session writes to `session-logs/YYYY-MM-DD-<machine>.md`.
- Open it at session start with the header `# YYYY-MM-DD-<machine> — IN PROGRESS`.
- Append short bullets as you go (what changed, decisions, blockers).
- Close it with `# ... — END` (the rules and `/handoff` finalize it).

## 7. End of session / before context compaction
Before finishing a session or when your context is about to be compacted:
- Commit + push everything.
- Write the `LAST SESSION` block in `CONTINUE.md` (machine, date, summary, NEXT STEPS).
- Mark the session log `END`, commit, and push once more.

## 8. Conflicts
- Prefer `git pull --rebase`. If a merge/rebase conflict occurs, resolve it immediately
  and note it in `CONTINUE.md`. Conflicts usually mean the "one machine at a time" rule
  was violated — say so.

## 9. Secrets & machine-local files
- Never commit API keys, tokens, or private configs. Use gitignored env files
  (`.env`, `.env.local`) and commit only `.env.example`.
- Never commit machine-local state or large generated files.

## 10. Machine awareness
The user works on machines of different power. Unless told otherwise:
- **Capable machine** (desktop/heavy laptop): may run builds, tests, and heavy toolchains.
- **Light machine**: prefer planning, writing, docs, and small edits. If a task needs a
  heavy build you cannot run here, record it as an explicit NEXT STEP for the capable
  machine instead of pretending it works.

## Machines
_Keep this list updated. Each entry: name, role, what it can build/run._
- `desktop` — capable: full builds/tests.
- `laptop-heavy` — capable: most builds.
- `laptop-light` — light: planning, writing, docs, small edits only.