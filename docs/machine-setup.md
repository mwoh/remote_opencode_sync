# Machine Setup Checklist

First step for a brand-new machine. Do this once per machine.

**Fastest path (does all of this automatically):**

```
curl -fsSL https://raw.githubusercontent.com/mwoh/remote_opencode_sync/main/scripts/bootstrap.sh | bash
```

The rest of this doc is the reference for what that script (and `scripts/setup-machine.sh`)
does, in case you prefer to run the checks by hand.

## 1. Install prerequisites

- **git** — `sudo apt install git` / `brew install git` / etc.
- **gh (GitHub CLI)** — `sudo apt install gh` / `brew install gh` / etc.
- **Node.js** — required for opencode via npm and for Bun-based plugins/shebang.
- **opencode** — `curl -fsSL https://opencode.ai/install | bash` (or `npm i -g opencode-ai`).

## 2. Authenticate with GitHub

```
gh auth login
```

Follow the prompts (browser login or paste a personal access token).

## 3. SSH key (needed for git over SSH)

Generate one if none exists:

```
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

Register it with GitHub:

```
gh ssh-key add ~/.ssh/id_ed25519.pub --title $(hostname)-opencode
```

## 4. Install the global session-sync plugin

This is the piece that makes sync zero-touch on every project, once per machine:

```
mkdir -p ~/.config/opencode/plugins
cp <toolkit>/plugins/session-sync.js ~/.config/opencode/plugins/session-sync.js
```

(Where `<toolkit>` is your clone of this repo.) Restart opencode after installing.

The plugin loads in every opencode session, but **only acts inside projects that carry the
`.opencode/toolkit` marker** (seeded into each project by `new-project.sh`) — every other
project is completely untouched. To turn it off for a single working copy on this machine:

```
touch .opencode/state/no-session-sync
```

(`.opencode/state/` is gitignored, so the opt-out stays local and never gets committed.)

## 5. Clone the toolkit repo (so it exists on this machine too)

> Skip this if you used the one-liner at the top — it already cloned the toolkit for you.

```
gh repo clone <you>/remote_opencode_sync
```

## 6. Verify

```
git --version && gh --version && node --version && opencode --version
ls ~/.config/opencode/plugins/
roe version     # shows installed + latest release (hints 'roe update' if behind)
```

(If `roe` isn't found yet, it's because `~/.local/bin` wasn't on your `PATH` before — setup
added the line to `~/.bashrc`; open a new shell or `source ~/.bashrc`.)

## 7. Model pinning (short version)

New projects pin the opencode model in their `opencode.jsonc` — your global opencode
config's model by default — so every machine that opens the repo runs the same one.
Override at creation with `roe new <name> --model <id>`; change it later with
`roe model <id>` (then commit + push). A machine without access to the pinned provider
will error at session start, exactly as it would if you picked that model manually.

## 8. Staying up to date

Two different things can get stale, and they update differently.

### The toolkit itself (`roe`)

```
roe version     # installed version + latest release; hints `roe update` if behind
roe update      # pulls the latest release and refreshes the plugin
```

There's nothing automatic here — `roe update` is the whole update path. Run it whenever
`roe version` says you're behind (or just periodically). It only ever fast-forwards, and
your local `@@GITHUB_USER@@` placeholder substitutions are re-applied each time.

### Your projects

**Automatic.** The global session-sync plugin does a `git pull --rebase` at every session
start and snapshots uncommitted work as a `wip:` commit when you go idle. You don't need
to pull or push by hand — `roe pull` / `roe push` exist for when the plugin is off or you
want explicit control, and `/resume` runs the same ritual as a command.

### Your session history (weekly)

```
roe history status     # is this machine's archive present and recent?
roe history backup     # archive it (what /handoff runs)
```

`status` exits non-zero when this machine has never archived (`missing`) or hasn't in
`--max-age-days` (default 7). `/sync` checks it for you and warns. Do it about weekly; the
archive is rolling, so a missed week costs you at most that week's transcripts.

### If you work *on* `roe` itself

That's a separate repo (the private `remote_opencode_sync-dev`), which is a normal roe
project: it auto-pulls at session start like any other. Two things to know:

- `roe update` refuses to run there (it's origin-guarded to the public distribution repo) —
  the dev repo updates via `git pull --rebase`, not `roe update`.
- `scripts/publish.sh` is how a dev-repo change reaches the public distribution; run
  `scripts/publish.sh --check` to see whether the public repo has drifted from the source.

## 9. Next steps

- Bring a project onto this machine: `gh repo clone <project>` → `cd <project>` →
  install deps → `opencode`.
- **Continue developing the toolkit itself** — that happens in the private development repo
  (`remote_opencode_sync-dev`), which is where you need `gh repo clone` access; open it with
  `opencode` and its `AGENTS.md` → `docs/agent-handoff.md` → `CONTINUE.md` will re-orient you
  from where the last session left off on any machine.
- Create a new project from anywhere: `roe new <name>` (alias for
  `scripts/new-project.sh <name>`).
- Update the toolkit later: `roe version` first (compares installed vs latest release),
  then `roe update`. Remove it: `roe uninstall` — it also removes the
  `roe` symlink and the PATH line setup added.

## What setup-machine.sh automates

Prerequisite install (via the detected package manager), `gh auth login`, SSH key
generate + register, a global git identity read from your GitHub profile, plugin install,
the `roe` command (a symlink to `bin/roe` in `~/.local/bin`, plus a `~/.bashrc` PATH entry
if `~/.local/bin` wasn't already there), and an uninstall manifest written to
`~/.local/state/remote_opencode_sync/uninstall.conf` (used by `scripts/uninstall.sh`). Its
main caveats:

- Package installs may ask for sudo / your distro's password.
- It only tries common package managers (`apt-get`, `brew`, `dnf`, `pacman`).
- It reports warnings instead of aborting, so you can fix stragglers and re-run.