# Agent Handoff — Takeover Guide

Read this first whenever you pick up this repo, then `PLAN.md` (design/architecture),
`README.md` (user-facing docs), `docs/machine-setup.md`, `docs/daily-workflow.md`, and
`docs/scripts-reference.md` as needed. This document is the **operational state**: what
exists, what is verified, how to run the tests, how to release, and every non-obvious
detail that took real effort to learn.

## 1. Current state

- **Latest release: v1.5.3** (tag `v1.5.3`). See the "Release history" table below.
- Everything described in `PLAN.md`'s roadmap through v1.5.3 is implemented and shipped.
- **Unreleased work on `main` (beyond v1.5.3, next tag):** vendored test harnesses +
  `docs/agent-handoff.md` + `AGENTS.md` standing instructions (all pushed), and the adopt
  hardening (dirty-tree warning, origin-repoint notice, branch-vs-default hint,
  `--follow-tags` — features suite now 71 checks). Not yet tagged.
- The repo is owned/administered by **`mwoh`** (`github.com/mwoh/remote_opencode_sync`).
  The bootstrap install SHA is pinned in each release's notes.
- **Known open/next items** (see `PLAN.md` roadmap): run `roe setup` on the remaining
  machines, `roe new` a real project and verify cross-machine resume end to end, and (if
  ever needed) rebuild the full 28-check model suite (it is now vendored — see §3).

### Release history

| Tag | Commit essence | Notes |
|-----|----------------|-------|
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
  desync.sh / resync.sh local-only opt-out of sync and its undo
  uninstall.sh          remove only what install created (manifest-driven)
  lib.sh                shared helpers (model pin, pkg mgr, placeholders, manifest)
plugins/
  session-sync.js       global opencode plugin: auto pull/rebase/push/wip (Layer 2)
templates/
  AGENTS.md.tpl, workflow-rules.md.tpl, CONTINUE.md.tpl, opencode.jsonc.tpl,
  .gitignore.tpl, .gitignore.append.tpl, .env.example.tpl
docs/
  machine-setup.md, daily-workflow.md, scripts-reference.md, agent-handoff.md
tests/                  VENDORED VERIFICATION HARNESSES (see §3)
  features.sh              sandbox e2e (71 checks) using tests/shims/gh
  model-features.sh        model-helper regression (28 checks)
  plugin-test.mjs          plugin behaviour harness (15 checks)
  shims/gh                 fake `gh` for the sandbox (bare repos under $GH_FAKE_ROOT)
LICENSE, README.md, PLAN.md
```

## 3. Verification & testing (the important part)

The repo has **three** test suites. They are the only verification apparatus. Run them
before any release; the sandbox suites clear fallback automatically.

```
cd <repo-root>
bash tests/features.sh        # 71 checks   (~40s; needs git, python3, node-agnostic)
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

`model-features.sh` exercises `model_from_global` / `model_get` / `model_resolve` /
`model_set` with controlled `HOME` values plus the `roe model` subcommand. It uses a
separate scratch root (`/tmp/opencode/modeltest`) so it never collides with `features.sh`.

## 4. Release process (step by step)

Before any release:

1. **Verify**: run all three suites + `bash -n` (§3). All green: features 71, model 28,
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
   `feat:`, `fix:`, `docs:`, `chore:`. **Only commit when the user asks.**
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
- **Only commit, push, tag, or release when explicitly asked.** The user drives cadence.
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
  your args; `version`/`help`/`model` are handled inline in `bin/roe` (there is no
  `model.sh`).
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
- **Desync** (`scripts/desync.sh`) is strictly local: `.opencode/state/no-session-sync`
  (gitignored) + `git update-index --skip-worktree` pins on the local stripped
  `AGENTS.md` / `.gitignore`. It never commits or pushes. `resync.sh` reverses exactly
  that (`--no-skip-worktree` + `git checkout --`).
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
| Day-to-day flows (resume, handoff, desync) | `docs/daily-workflow.md` |
| Installing a machine | `docs/machine-setup.md` |
| Verifying changes | `tests/` (this §3), release notes |
| Plugin behaviour & its quiet gating | `plugins/session-sync.js` |
| Seeding/conflict resolution | `scripts/new-project.sh`, `templates/` |