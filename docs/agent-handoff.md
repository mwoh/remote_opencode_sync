# Agent Handoff — Takeover Guide

Read this first whenever you pick up this repo, then `PLAN.md` (design/architecture),
`README.md` (user-facing docs), `docs/machine-setup.md`, `docs/daily-workflow.md`, and
`docs/scripts-reference.md` as needed. This document is the **operational state**: what
exists, what is verified, how to run the tests, how to release, and every non-obvious
detail that took real effort to learn.

## 1. Current state

- **Latest release: v1.5.9** (tag `v1.5.9`). See the "Release history" table below.
- Everything described in `PLAN.md`'s roadmap through v1.5.9 is implemented and shipped.
- The repo is owned/administered by **`mwoh`** (`github.com/mwoh/remote_opencode_sync`).
  The bootstrap install SHA is pinned in each release's notes.
- **Known open/next items** (see `PLAN.md` roadmap): run `roe setup` on the remaining
  machines, `roe new` a real project and verify cross-machine resume end to end, and (if
  ever needed) rebuild the full 28-check model suite (it is now vendored — see §3).

### Release history

| Tag | Commit essence | Notes |
|-----|----------------|-------|
| v1.5.9 | `roe history` — per-(project × machine) session-history backups. opencode keeps every project's conversations in one local db (`~/.local/share/opencode/opencode.db`), which is *not* in any repo, so deleting it wipes the machine's history. `history.sh backup` reads the db **read-only** and writes a rolling `opencode-history/<host>.jsonl.gz` **inside the repo** (travels via normal sync); `list`/`show` render any machine's archive; `--host`/`OPENCODE_DB` overrides. `/handoff` backs up, `/sync` warns when the archive is missing/>7d. `scripts/history.py` is python3 stdlib only (second AGENTS.md carve-out) | features suite 145 → 176 checks (§M) |
| v1.5.8 | `roe track` — see/change what a project actually syncs. Because the idle `wip:` snapshot does `git add -A`, `.gitignore` is the true sync boundary; `track` edits only the `# --- added by remote_opencode_sync ---` block. `--list`/`--ignore`/`--unignore` flags + a curses TUI (`scripts/track_tui.py`, python3 **standard-library only** via a standing AGENTS.md carve-out); `project_root` walk-up in `lib.sh` (also lets status-style scripts accept subdirectories); escape guard | features suite 115 → 145 checks (§L) |
| v1.5.7 | `roe status` / `roe pull` / `roe push` / `roe upgrade` — the sync-state advisory + manual in/out halves of the sync + a non-destructive per-project seed refresh. Shared seed-detection predicates in `lib.sh` (`project_has_marker`/`project_desynced`/`project_commands_current`/`project_rules_current`/`project_gitignore_current`/`project_seed_stale`) and a comment-aware `jsonc_inject_block` restore the fallback commands while keeping the pinned model | features suite 79 → 115 checks (§K) |
| v1.5.6 | `roe version` reports installed + latest release (git tags; pure bash/awk; offline-graceful; sandbox-tested via fake origin) | features suite 75 → 79 checks |
| v1.5.5 | the toolkit repo self-hosts its own workflow (marker, config, CONTINUE.md, session logs, rules header) — clone → `roe setup` → `opencode` = full handoff on any machine | features suite 71 → 75 checks (§I guards the self-host markers) |
| v1.5.4 | adopt hardening (dirty-tree warning, origin-repoint notice, branch/default hint, `--follow-tags`); vendored tests + takeover guide + AGENTS.md; always-release cadence rule | features suite 61 → 71 checks |
| v1.5.3 | fix `model_set` injection comma vs trailing `//` comment | comment-aware awk in `scripts/lib.sh` |
| v1.5.2 | resumable `new`/`adopt`, `desync`/`resync`, `projects`/`clone`, plugin silent in non-toolkit projects | biggest feature release |
| v1.5.1 | fix seeded `prompt` → `template` schema break | migration note for the adopted project |
| v1.5.0 | per-project model pinning (`--model`/`$MODEL_PIN`/`roe model`) | |
| v1.4.0 | `roe` command front-end | |
| v1.3.x | per-session debounce, uninstall, plugin project-gating | |
| v1.2.0 | adopt-existing + update.sh + docs | |
| v1.0.0 / v1.1.0 | initial toolkit + GitHub repo | |

## 2. Repo layout

```
bin/roe                 the roe front-end (bash function main; dispatches scripts)
scripts/
  bootstrap.sh          one-liner install/update entry (curl pipe)
  update.sh             update an installed toolkit (origin-guarded)
  setup-machine.sh      one-time machine setup; writes the uninstall manifest
  new-project.sh        create/adopt a synced project (resumable); seeds templates
  projects.sh           list synced projects (marker-probed) + clone
  status.sh             `roe status` — valid project? what does it need? (0/2/1 exit)
  pull.sh / push.sh     manual in/out halves of the sync (stash-safe rebase / non-FF-safe push)
  upgrade.sh            non-destructive refresh of a project's seed files to the current toolkit
  track.sh / track_tui.py  `roe track` sync-scope list/ignore/unignore + curses TUI (python3 stdlib)
  history.sh / history.py  `roe history` per-machine session-history backup/list/show (db read-only; python3 stdlib)
  desync.sh / resync.sh local-only opt-out of sync and its undo
  uninstall.sh          remove only what install created (manifest-driven)
  lib.sh                shared helpers (model pin, pkg mgr, placeholders, manifest, project seed detection, jsonc block inject)
plugins/
  session-sync.js       global opencode plugin: auto pull/rebase/push/wip (Layer 2)
templates/
  AGENTS.md.tpl, workflow-rules.md.tpl, CONTINUE.md.tpl, opencode.jsonc.tpl,
  .gitignore.tpl, .gitignore.append.tpl, .env.example.tpl
docs/
  machine-setup.md, daily-workflow.md, scripts-reference.md, agent-handoff.md
tests/                  VENDORED VERIFICATION HARNESSES (see §3)
  features.sh              sandbox e2e (176 checks) using tests/shims/gh
  model-features.sh        model-helper regression (28 checks)
  plugin-test.mjs          plugin behaviour harness (15 checks)
  shims/gh                 fake `gh` for the sandbox (bare repos under $GH_FAKE_ROOT)
AGENTS.md               standing rules (incl. `## 1. Session start` — self-hosted)
CONTINUE.md             this repo's running handoff / cross-device memory
session-logs/           this repo's running session log
opencode.jsonc          self-host config: pinned model + /resume, /handoff, /sync
.gitignore              self-host ignore rules
.opencode/toolkit       self-host marker (this repo is itself a toolkit project)
LICENSE, README.md, PLAN.md
```

> **Self-hosting note:** this repo carries the toolkit marker, so the global
> session-sync plugin acts here too — auto pull/rebase on session start, `wip:` commits
> on idle, CONTINUE.md + session log injected into compaction. `CONTINUE.md` is the
> running handoff to keep fresh; `tests/features.sh` §I regresses the markers so the
> self-hosting can't silently regress.

## 3. Verification & testing (the important part)

The repo has **three** test suites. They are the only verification apparatus. Run them
before any release; the sandbox suites clear fallback automatically.

```
cd <repo-root>
bash tests/features.sh        # 176 checks  (~60s; needs git, python3, node-agnostic)
bash tests/model-features.sh  # 28 checks
node tests/plugin-test.mjs    # 15 checks   (needs node)
bash -n scripts/*.sh bin/roe tests/*.sh   # syntax sweep
```

All three are independent and locally sandboxed (no network, no real GitHub). Optional
env: `ROE_REPO` (point at a different checkout), `ROE_SANDBOX_ROOT` (change the scratch
dir). Expected results are pinned in §4 release checklist.

### How the sandbox works (must-know)

`features.sh` and `model-features.sh` use a **fake `gh`** (`tests/shims/gh`) backed by a
directory of bare repos under `$GH_FAKE_ROOT/<owner>/<name>.git`, with `origin` URLs
pointed at them through `GITHUB_SSH_BASE`. The environment they export:

```
GH_FAKE_ROOT=$ROOT/ghroot        # the "GitHub" (bare repo dir)
GH_FAKE_AUTH=yes                 # gh auth status -> ok
GH_FAKE_OWNER=fakeuser
GITHUB_SSH_BASE="file://$GH_FAKE_ROOT/"   # NB: trailing slash is REQUIRED —
GITHUB_USER=fakeuser                      #     it is the URL separator; without it
PATH=$tests/shims:$PATH                   #     URLs mangle to .../ghrootfakeuser/...
HOME=$ROOT/home-fake                      # isolated global git identity/cache
```

Hard-won gotchas (do not "fix" these away):

1. **`features.sh` wipes `$ROOT`**: `rm -rf "${ROOT:?}"/*` at startup. Keep the script
   and the shims **outside** `$ROOT` (they are under `tests/` for exactly this reason).
2. **Fresh GitHub repos point `HEAD` at `refs/heads/main`.** The shim's `repo create`
   runs `git symbolic-ref HEAD refs/heads/main` on the new bare. `features.sh` has a
   `mkbare()` helper for pre-created bares that does the same. Assert bare contents with
   `git --git-dir <bare> log --oneline -1` (HEAD-based), not a hard-coded branch.
3. **`repo list` hard-fails when `$FAKE_ROOT/$OWNER` is missing** (`gh: API unreachable`,
   exit 1). This deliberately exercises the offline/`--refresh` cache-fallback path — an
   empty scan used to "succeed" and overwrite the cache with nothing.
4. Optional `<name>.git.roe-meta` files set `private=` / `archived=` / `description=`
   metadata for the fake `repo list`.
5. **The plugin fires fire-and-forget events**: `void syncStart()` / `void syncIdle()`.
   Harness assertions must **settle ~800 ms** after firing an event before reading results
   (`plugin-test.mjs` does this). Plugin log payloads arrive as `{ body: { level,
   message } }` — the harness reads `payload.body ?? payload`.
6. **`bin/roe` has no `package.json type:module`**, so `plugin-test.mjs` imports a temp
   copy of `plugins/session-sync.js` **renamed `.mjs`** so node treats it as ESM.
7. `scripts/lib.sh` and the runtime scripts are deliberately dependency-light: **no `jq`,
   no `python`, no node in shipped code** (`gh --template` renders JSON; awk/sed do text
   work). Python may appear only inside test assertions.
   - **TWO standing exceptions (both user-approved, python3 standard-library only, no
     pip):**
     - v1.5.8: the interactive `roe track` UI is `scripts/track_tui.py` — a thin
       presentation layer over `track.sh`, stdlib `curses`. Flag modes work everywhere and
       the TUI falls back to the text report when python3/`curses`/a TTY is missing. All
       state mutation stays in bash (`track.sh`), the scriptable surface.
     - v1.5.9: `scripts/history.py` is the read-only opencode-db exporter/reader behind
       `roe history` — stdlib `sqlite3`/`json`/`gzip`. It opens the db with a `mode=ro`
       URI and must **never** write opencode state; all mutation/decision logic stays in
       bash (`history.sh`).

`model-features.sh` exercises `model_from_global` / `model_get` / `model_resolve` /
`model_set` with controlled `HOME` values plus the `roe model` subcommand. It uses a
separate scratch root (`/tmp/opencode/modeltest`) so it never collides with `features.sh`.

## 4. Release process (step by step)

Before any release:

1. **Verify**: run all three suites + `bash -n` (§3). All green: features 176, model 28,
   plugin 15.
2. **Bump docs** — a version bump updates these **together, in the same commit**:
   - `README.md`: the pinned "safer variant" install line (`…/vX.Y.Z/scripts/bootstrap.sh`)
     and any behavior claims touched by the release;
   - `PLAN.md`: roadmap checkboxes;
   - this document: "Current state" + "Release history";
   - the gh release notes (with the bootstrap SHA block).
   If any suite's check count changed since the last release, update the claimed counts
   in README, PLAN, this doc, and the release notes in the same change too.
3. **Commit** with the repo's style: `type: <lowercase subject> (vX.Y.Z)` using one of
   `feat:`, `fix:`, `docs:`, `chore:`. Commit as part of the change set — no need to ask.
4. **Tag** an annotated tag: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`
   (and push `main`).
5. **Verify the bootstrap SHA at the tag** (regardless of whether `bootstrap.sh` changed):
   ```
   curl -fsSL https://raw.githubusercontent.com/mwoh/remote_opencode_sync/vX.Y.Z/scripts/bootstrap.sh | shasum -a 256
   ```
   - Expected: `cf494b716b59620eddd891ccdbcde8bf2d9a184c7864afebd3d95adc97b513f2`
   - This SHA is stable **unless `scripts/bootstrap.sh` itself changes**. If it does
     change, compute the new SHA and update it in the release notes (users pin against
     the release notes, not the README).
6. **Create the release** with notes:
   ```
   gh release create vX.Y.Z --title "<title>" --notes-file /tmp/opencode/release-notes.md
   ```
   Release notes must include the install/update curl block with the SHA and a
   verification summary (suite counts). Example format: see `v1.5.2` / `v1.5.3` on
   GitHub (`gh release view v1.5.2 --json body --jq .body`).
7. **Update** `PLAN.md` roadmap + this doc's "Current state" / release history.

## 5. Working conventions

- **Never leave anything stale.** Any change ships as **one coherent change set**:
  when you touch code (or templates, plugins, `bin/roe`), update in the same change —
  the code itself, the tests that cover it (`tests/*`, re-run them), `README.md`
  (command tables, layout listing, pinned install URL, behavior claims), `PLAN.md`
  (component table + roadmap checkboxes), `docs/scripts-reference.md` (options,
  dispatch, env vars), `docs/daily-workflow.md` / `docs/machine-setup.md` (only if
  behavior touches those flows — check, don't assume), this document (Current state,
  release history, test counts, gotchas), and release notes/SHA when a release is cut.
- **Test-count rule:** when a suite's check count changes, update the printed claim of
  that count everywhere it appears (README, PLAN, this doc, release notes) in the same
  change. A stale count is a bug.
- **Commit, push, tag, and release as part of finishing the work — don't wait to be asked.**
  Every coherent change set ships as a tagged release (label `(vX.Y.Z)`); follow §4 end
  to end, push the tag + `main`, and call the release out in the summary.
- Commit-message style: `type(scope): summary` → actually the repo uses
  `type: summary (vX.Y.Z)` (no scope) for shipped versions; see `git log` for precedent.
- Runtime code must stay **dependency-light bash** (no jq/python/node in scripts).
- Test harnesses **must** remain runnable with zero installs beyond git + node + python3.
- The user's real toolkit projects (the payload, e.g. older adopted projects) use the
  pinned model workflow; changing seeded templates should stay backward-compatible with
  the marker shape (`.opencode/toolkit` containing `remote_opencode_sync`) and the
  `## 1. Session start` rules header, because the plugin, `projects.sh`, `desync.sh`,
  and `new-project.sh` all detect by these exact markers.
- Docs live in `docs/` and are referenced from `README.md`'s layout; add new docs there
  and register them.

## 6. Gotchas & landmines encountered (refer before touching code)

- **Resume vs collision detection** (`new-project.sh`): "empty repo" is decided by
  `git ls-remote "$SSH_URL" 'refs/heads/*'` **counting refs**, not by checking the
  default-branch HEAD. A repo whose default branch is not `main` but has commits would
  otherwise be misread as an empty stub. Resume = leftover clone whose `origin` equals
  the target URL, or an empty stub repo; everything else is a genuine collision → refused
  with a hint.
- **`roe` argument injection** (see `docs/scripts-reference.md`): `adopt` forwards
  `--existing <dir>` then your args; `projects`/`clone` forward the subcommand word then
  your args; `status`/`pull`/`push`/`upgrade` are complete pass-through (one optional
  target dir, defaulting to the current directory); `track` and `history` are complete
  pass-through too, though their project resolution walks up to the marker rather than
  defaulting to the cwd (`history` also takes its own `backup`/`list`/`show` subcommand);
  `version`/`help`/`model` are handled
  inline in `bin/roe` (there is no `model.sh`). `roe version` since v1.5.6 appends
  `latest: …` by `git ls-remote --tags` against the toolkit's origin + `ver_sort_max`/
  `ver_gt` (awk, `lib.sh`) — update hints only when the remote tag is strictly newer,
  and offline it prints `latest: unknown` without erroring.
- **Adopt hardening** (`scripts/new-project.sh`): adopting warns when the pre-existing tree
  is dirty and bundles those changes into the import commit (warn-and-continue, captured
  *before* seeding); replacing a foreign `origin` under `--force` names the old URL;
  pushes annotated tags with `--follow-tags`; and after a successful push warns when the
  pushed branch differs from the remote's `default_branch` (via `gh api … --jq
  .default_branch`, falling back to `git ls-remote --symref` when no default can be read —
  the ls-remote fallback is silent for *unborn* default branches, which is exactly the
  fresh-empty-repo case the `gh api` path catches).
- **`GITHUB_SSH_BASE` must include the URL separator**: `git@github.com:` or
  `file:///tmp/fake/` (trailing slash). It is prepended verbatim to `${OWNER}/${NAME}.git`.
- **`model_set` injection** (`scripts/lib.sh`) is comment-aware: it inserts the
  separator comma *before* a trailing `// comment` (not inside it) and ignores `//` that
  occur inside quoted strings (e.g. `https://opencode.ai/config.json`). Preserve that
  behaviour if you touch the awk.
- **Seed idempotency**: `.gitignore.tpl` starts with a `# --- added by remote_opencode_sync
  ---` marker, and `already_marked()` also accepts an existing `## 1. Session start`
  block in `AGENTS.md` as "already synced". This prevents a duplicate-seed commit when a
  create is interrupted and resumed. Keep both markers in sync if you restructure seeding.
- **The rules marker has TWO accepted shapes** (lib.sh `project_rules_current`, since
  v1.5.7): the full template's `## 1. Session start` header **or** the append block's
  `<!-- appended by remote_opencode_sync … -->` comment — the append block numbers its
  headings instead of using the header. `new-project.sh`'s `already_marked()` accepts
  both too. If you only checked the header, `roe status`/`roe upgrade` would loop on any
  project restored by the append path (duplicate-appending the rules on every upgrade).
- **`roe status` exit codes**: `0` = valid + everything current, `1` = not a roe project /
  not a usable git copy, `2` = valid but an action is needed. It is the ONLY script with a
  trichotomy; everything else is 0/1. Seed drift uses the same `project_seed_stale`
  predicate as `upgrade.sh`, so status and upgrade can never disagree.
- **`roe upgrade` is deliberately conservative**: refuses to run over a dirty tree (it
  never bundles your work into the refresh commit), and on a **desynced** copy skips the
  `AGENTS.md`/`.gitignore` writes entirely (those files are `--skip-worktree` pinned, so
  edits would be silently ignored). It also never rewrites a config whose `command` key
  exists but is incomplete — that is flagged for a manual merge — and never touches a
  rules/ignore block that is already marked.
- **`roe track` edits ONLY the roe block** (`track.sh`): the `# --- added by
  remote_opencode_sync ---` region of the project's `.gitignore`. User-written ignore rules
  anywhere else are reported but never touched; `--unignore` **refuses (exit 1)** a path
  whose only rule lives outside the block. The script idempotently re-uses existing
  patterns and only ever calls `git rm --cached` for *tracked* targets (files stay on
  disk). Root-relative path normalization refuses `..`/absolute escapes (exit 1).
- **`roe track` cross-machine caveat**: a `.gitignore` rule propagates via push, but it
  never un-tracks a file that is already in history elsewhere — the other machine needs to
  pull (and touch/re-add the file) for the change to take effect. This is by design (git
  semantics), printed in the TUI's help, and must be preserved in tests. The `project_root`
  walk-up (lib.sh) resolves from any subdirectory; it bails (exit 1) when no `.opencode/toolkit`
  marker exists above, and it is also what lets status-style scripts accept a subdirectory.
- **The TUI is presentation-only**: `track_tui.py` never edits state itself — it shells
  back to `track.sh --list`/`--ignore`/`--unignore` (the tested/scriptable surface), so a
  bug in the UI can't corrupt a repo. It must stay python3 standard-library-only; the TUI
  falls back to `--list` output when `curses`, a TTY, or python3 is missing.
- **`roe history` never writes opencode's db** (`history.py`): it opens
  `~/.local/share/opencode/opencode.db` (or `$OPENCODE_DB`/`--db`) with a `mode=ro` URI.
  The archive `<project>/opencode-history/<host>.jsonl.gz` is a **rolling** file per
  machine — re-running `backup` overwrites it, so the repo stays small. Sessions are
  matched to the project by `project.worktree` / `project_directory.directory` /
  `session.directory`; a different project on the same machine is never included (this
  matching is a §M test invariant). If opencode ever moves its db schema, matching — not
  the read-only guarantee — is what to re-check.
- **`opencode-history/` normally stays committed and un-ignored** (it travels via the
  normal sync) — don't let it land in the roe `.gitignore` block, and keep it out of
  `track --ignore`; the `/sync` 7-day nag only works if the archive is really in the repo.
  **Exception: a public repo.** An archive is the full raw transcript, so this toolkit's own
  public repo gitignores `opencode-history/` (`roe track --ignore opencode-history`).
  `history.sh backup` runs `git check-ignore` and prints a "will NOT sync" note in that case
  (the M9 test invariant), so a user is never silently misled. Keep project repos private.
- **Recovery is read/replay, not a db merge**: opencode exposes no supported way to merge
  an archived db fragment back in. `roe history show` gives readable transcripts and the
  JSONL keeps every message/part's raw JSON for future tooling — never claim byte-level
  restore in docs.
- **`jsonc_inject_block`** (lib.sh, v1.5.7) generalizes the `model_set` comment-aware awk:
  it inserts a multi-line block before the final closing brace, adding the separator comma
  to the previous element and respecting trailing `//` comments. `roe upgrade` uses it to
  restore the fallback command block without a JSON tool; the block itself is extracted at
  runtime from `templates/opencode.jsonc.tpl` (never duplicated in the script).
- **Desync** (`scripts/desync.sh`) is strictly local: `.opencode/state/no-session-sync`
  (gitignored) + `git update-index --skip-worktree` pins on the local stripped
  `AGENTS.md` / `.gitignore`. It never commits or pushes. `resync.sh` reverses exactly
  that (`--no-skip-worktree` + `git checkout --`).
- **Self-hosting** (since v1.5.5): the toolkit repo carries its own `.opencode/toolkit`
  marker, so the global plugin acts here. Anything left uncommitted during an opencode
  session in this repo is auto-committed as `wip:` and **pushed to `main`** (which feeds
  the curl installer) — keep the tree clean at release time and treat `wip:` as backup,
  not as a substitute for proper change sets. The plugin never tags or releases.
- **Uninstall must never `rm -rf` outside `$HOME`** or anything that doesn't look like a
  toolkit clone — guarded in `uninstall.sh`. The manifest path defaults to
  `~/.local/state/remote_opencode_sync/uninstall.conf` and is overridable via
  `UNINSTALL_STATE_DIR` / `UNINSTALL_MANIFEST`.
- Model precedence everywhere: `--model` > `$MODEL_PIN` > global opencode config >
  interactive prompt; on a resume, never re-prompt (an existing `opencode.json(c)`
  suppresses the prompt).

## 7. Where to look for each area of concern

| Concern | Start at |
|---------|----------|
| Why it exists / how it works | `PLAN.md`, `README.md` |
| Per-script options & roe wiring | `docs/scripts-reference.md` |
| Day-to-day flows (resume, handoff, desync, track, history) | `docs/daily-workflow.md` |
| Installing a machine | `docs/machine-setup.md` |
| Verifying changes | `tests/` (this §3), release notes |
| Plugin behaviour & its quiet gating | `plugins/session-sync.js` |
| Seeding/conflict resolution | `scripts/new-project.sh`, `templates/` |
| Sync-scope / `.gitignore` roe-block editing | `scripts/track.sh`, `scripts/track_tui.py` |
| Session-history backups / opencode db | `scripts/history.sh`, `scripts/history.py` |