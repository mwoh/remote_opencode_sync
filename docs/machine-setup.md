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

## 5. Clone the toolkit repo (so it exists on this machine too)

```
gh repo clone <you>/remote_opencode_sync
```

## 6. Verify

```
git --version && gh --version && node --version && opencode --version
ls ~/.config/opencode/plugins/
```

## 7. Next steps

- Bring a project onto this machine: `gh repo clone <project>` → `cd <project>` →
  install deps → `opencode`.
- Create a new project from anywhere: `scripts/new-project.sh <name>`.

## What setup-machine.sh automates

Prerequisite install (via the detected package manager), `gh auth login`, SSH key
generate + register, and plugin install. Its mains caveats:

- Package installs may ask for sudo / your distro's password.
- It only tries common package managers (`apt-get`, `brew`, `dnf`, `pacman`).
- It reports warnings instead of aborting, so you can fix stragglers and re-run.