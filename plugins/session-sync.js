// session-sync.js — zero-touch cross-device sync for opencode (Layer 2 safety net).
//
// Install once per machine so it applies everywhere:
//   cp plugins/session-sync.js ~/.config/opencode/plugins/session-sync.js
//
// The plugin is loaded in EVERY opencode session, but only acts in projects that
// carry the toolkit marker (`.opencode/toolkit`, seeded + committed by
// new-project.sh) — other projects are completely untouched, silently (no logs).
// A local marker `.opencode/state/no-session-sync` (gitignored) opts a single
// working copy out.
//
// What it does:
//   session.created  -> git plumbing: fetch, safe stash/pop, `pull --rebase`,
//                       push if local-ahead & clean. Also ensures today's session log exists.
//   session.idle     -> (debounced ~2 min) if the tree is dirty, auto-commit a
//                       `wip: <host> <stamp>` snapshot + push, and append a note to the log.
//   compacting       -> inject CONTINUE.md + the latest session log into the compaction
//                       prompt so context compression keeps continuity.
//
// Layer 1 (the AGENTS.md rules in each project) remains the authoritative sync path —
// this plugin only ever catches what the rules have not already committed. It never
// rewrites or conflicts with them.

import { hostname } from "node:os"
import { existsSync } from "node:fs"
import path from "node:path"

const HOST = hostname().split(".")[0]
const IDLE_DEBOUNCE_MS = 120_000
const START_DEBOUNCE_MS = 60_000

export const SessionSync = async (ctx) => {
  const worktree = ctx.worktree ?? ctx.directory

  // Debounce state lives PER SESSION (per project), not module-global, so opening
  // a second project right after the first doesn't suppress its first sync.
  let lastIdleSync = 0
  let lastStartSync = 0
  let idleWarned = false
  let startWarned = false

  const log = async (level, message) => {
    const line = `[session-sync] ${message}`
    try {
      await ctx.client.app.log({ body: { service: "session-sync", level, message } })
    } catch {
      console.log(line)
    }
  }

  // Run a command string in the project worktree. Returns { ok, text, err }.
  //
  // IMPORTANT: `ctx.$` is Bun's `$` shell, and it does NOT shell-parse an
  // interpolated value — an interpolation is passed as a SINGLE literal argument.
  // So `ctx.$`${cmd}`` would try to execute the whole command string as one command
  // NAME and fail with `bun: command not found: ...`. Passing it through `sh -c`
  // gives `sh` the string as one argument (exactly what -c wants), which then
  // parses it normally.
  //
  // `.quiet()` stops command output being echoed into the user's session;
  // `.nothrow()` keeps a non-zero exit from throwing (a thrown error under .quiet()
  // loses stderr, which is what the failure warnings below report).
  const sh = async (cmd) => {
    try {
      const r = await ctx.$`sh -c ${cmd}`.cwd(worktree).quiet().nothrow()
      return {
        ok: r.exitCode === 0,
        text: r.stdout.toString(),
        err: r.stderr.toString(),
      }
    } catch (err) {
      const msg = err?.stderr?.text ? err.stderr.text() : err?.message ?? String(err)
      return { ok: false, text: "", err: String(msg) }
    }
  }
  // Best available diagnostic for a failed command: real stderr, else whatever
  // landed on stdout, else a generic exit-code note.
  const diag = (r) => (r.err || r.text || "").trim() || `exit code ${r.code ?? "?"}`
  const git = (cmd) => sh(`git ${cmd}`)

  const isRepo = async () => (await git("rev-parse --is-inside-work-tree")).ok
  const hasRemote = async () => (await git("remote get-url origin")).ok

  // A project is "using the toolkit" only if it carries the marker that
  // new-project.sh seeds (committed, so clones have it too). This keeps the
  // globally-loaded plugin a no-op in every project that isn't a toolkit one.
  // A local (gitignored) .opencode/state/no-session-sync file opts a single
  // working copy out on this machine.
  const isToolkitProject = async () => {
    // Checked with fs (not the shell) because this runs in EVERY opencode session
    // everywhere: two stat calls cost nothing, whereas spawning shells just to test
    // for a file would be visible noise in projects that don't use the toolkit.
    // Re-checked on every call so `roe desync` / `roe resync` run MID-SESSION take
    // effect immediately instead of after an opencode restart.
    const marker = existsSync(path.join(worktree, ".opencode/toolkit"))
    const optout = existsSync(path.join(worktree, ".opencode/state/no-session-sync"))
    return marker && !optout
  }

  // Only one sync may run at a time. syncStart and syncIdle are fired fire-and-forget
  // (`void`), so without this an idle `git add -A`/`commit` can land in the middle of
  // the start sync's stash -> pull -> pop window.
  let syncInFlight = false
  const withSyncLock = async (fn) => {
    if (syncInFlight) return false
    syncInFlight = true
    try {
      await fn()
    } finally {
      syncInFlight = false
    }
    return true
  }

  const dateStamp = () => new Date().toISOString().slice(0, 10)
  const timeStamp = () =>
    new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)

  // --- session log helpers (best-effort, never fatal) ---
  const meta = async () => {
    const date = dateStamp()
    const file = `${date}-${HOST}.md`
    const exists = existsSync(path.join(worktree, "session-logs", file))
    return { date, file, exists }
  }

  const ensureSessionLog = async () => {
    const { file, exists } = await meta()
    await sh("mkdir -p session-logs")
    if (!exists) {
      await sh(`printf '# %s — IN PROGRESS\\n\\n' "${file}" >> "session-logs/${file}"`)
    }
  }

  const appendSessionLog = async (line) => {
    const { file, exists } = await meta()
    await sh("mkdir -p session-logs")
    if (!exists) {
      await sh(`printf '# %s — IN PROGRESS\\n\\n' "${file}" >> "session-logs/${file}"`)
    }
    await sh(`printf '%s\\n' "${line}" >> "session-logs/${file}"`)
  }

  // --- session start: pull / rebase / push plumbing ---
  const syncStartInner = async () => {
    try {
      // Guard FIRST: a project that isn't a toolkit project must be completely
      // invisible — no shell, no bookkeeping, and above all no log lines (the
      // debounce log below would otherwise fire here on repeated events).
      if (!(await isToolkitProject())) return

      const now = Date.now()
      if (now - lastStartSync < START_DEBOUNCE_MS) {
        if (!startWarned) {
          startWarned = true
          await log("info", "skipping start sync (debounced: already synced recently this session)")
        }
        return
      }
      lastStartSync = now
      startWarned = false

      if (!(await isRepo())) return
      if (!(await hasRemote())) return // local-only project; nothing to sync

      const upstream = await git("rev-parse --abbrev-ref --symbolic-full-name @{upstream}")
      if (!upstream.ok) return // unborn branch / detached HEAD — skip silently
      const remote = upstream.text.trim()

      const fetched = await git("fetch origin")
      if (!fetched.ok) {
        // Ignoring this made "already synced" be asserted by silence: behind stayed 0
        // because the remote-tracking ref was stale, and nothing was logged.
        await log("warn", `start fetch failed (${diag(fetched)}) — skipping sync`)
        return
      }
      const behindR = await git(`rev-list --count HEAD..${remote}`)
      const aheadR = await git(`rev-list --count ${remote}..HEAD`)
      const behind = behindR.ok ? parseInt(behindR.text.trim() || "0", 10) : 0
      const ahead = aheadR.ok ? parseInt(aheadR.text.trim() || "0", 10) : 0

      const status = await git("status --porcelain")
      const dirty = status.ok && status.text.trim() !== ""

      if (!dirty && ahead > 0 && behind === 0) {
        const push = await git("push")
        if (!push.ok) await log("warn", `start push failed: ${push.text.trim()}`)
      }

      let stashed = false
      if (behind > 0 && dirty) {
        // -u matters: `--porcelain` counts untracked files as dirty, but a plain
        // `stash push` doesn't stash them and still exits 0. Without verifying a stash
        // entry was really created, the later `stash pop` would pop the user's own
        // oldest stash and merge unrelated old work into the tree.
        const beforeR = await git("stash list")
        const before = beforeR.ok ? beforeR.text.split("\n").filter(Boolean).length : 0
        const st = await git('stash push -u -m "session-sync: pre-pull"')
        if (!st.ok) {
          await log("warn", `start stash failed (${diag(st)}) — leaving tree alone`)
          return
        }
        const afterR = await git("stash list")
        const after = afterR.ok ? afterR.text.split("\n").filter(Boolean).length : 0
        stashed = after > before
      }

      if (behind > 0) {
        const pull = await git("pull --rebase")
        if (!pull.ok) {
          // Restore the stash before bailing out — otherwise the user's work sits
          // invisible in the stash for the rest of the session. The common failure
          // here is untracked files blocking the merge, not a merge conflict.
          if (stashed) {
            const pop = await git("stash pop")
            if (!pop.ok) {
              await log("warn", `start stash pop after failed pull conflicted: ${diag(pop)} — run 'git stash pop' manually`)
            }
          }
          await log("error", `start pull failed: ${diag(pull)}`)
          return
        }
        if (stashed) {
          const pop = await git("stash pop")
          if (!pop.ok) {
            await log("warn", `start stash pop conflicted: ${diag(pop)} — run 'git stash pop' manually`)
          }
        }
        await log("info", "pulled latest changes from remote")
      }

      await ensureSessionLog()
    } catch (err) {
      await log("error", `unexpected sync-start error: ${err?.message ?? String(err)}`)
    }
  }
  const syncStart = async () => {
    await withSyncLock(syncStartInner)
  }

  // --- session idle: snapshot any uncommitted work as a wip commit ---
  const syncIdleInner = async () => {
    try {
      // Guard FIRST: same contract as syncStart — non-toolkit projects never log.
      if (!(await isToolkitProject())) return

      const now = Date.now()
      if (now - lastIdleSync < IDLE_DEBOUNCE_MS) {
        if (!idleWarned) {
          idleWarned = true
          await log("info", "skipping idle snapshot (debounced: already synced recently this session)")
        }
        return
      }
      lastIdleSync = now
      idleWarned = false

      if (!(await isRepo())) return
      if (!(await hasRemote())) return
      // Mirrors syncStart's guard: on a detached HEAD or an unborn branch a commit here
      // would land on a dangling ref (recoverable only via reflog) and `git push` would
      // fail with "no upstream" — i.e. the snapshot silently disappears.
      const upstream = await git("rev-parse --abbrev-ref --symbolic-full-name @{upstream}")
      if (!upstream.ok) return

      const status = await git("status --porcelain")
      if (!status.ok || status.text.trim() === "") return // nothing to snapshot

      const stamp = timeStamp()
      await appendSessionLog(`- [auto] wip snapshot ${stamp} (${HOST})`)

      const commit = await git(`add -A && git commit -m "wip: ${HOST} ${stamp}"`)
      if (!commit.ok) {
        await log("warn", `idle snapshot commit failed: ${diag(commit)}`)
        return
      }
      const push = await git("push")
      if (!push.ok) await log("warn", `idle snapshot push failed: ${diag(push)}`)
      await log("info", `auto-saved uncommitted work (wip: ${HOST} ${stamp})`)
    } catch (err) {
      await log("error", `unexpected idle-sync error: ${err?.message ?? String(err)}`)
    }
  }
  const syncIdle = async () => {
    await withSyncLock(syncIdleInner)
  }

  // --- compaction: keep continuity across context compression ---
  const catFile = async (name) => {
    const r = await sh(`cat "${name}" 2>/dev/null || true`)
    return r.ok ? r.text : ""
  }

  return {
    event: async ({ event }) => {
      if (event.type === "session.created") void syncStart()
      else if (event.type === "session.idle") void syncIdle()
    },

    "experimental.session.compacting": async (_input, output) => {
      try {
        if (!(await isToolkitProject())) return
        const cont = await catFile("CONTINUE.md")
        if (!cont) return
        const tail = await catFile(`session-logs/${dateStamp()}-${HOST}.md`)
        const context = []
        context.push("### Sync context (from session-sync plugin)")
        context.push("Cross-device continuation notes — use this to stay oriented after compaction:")
        context.push("#### CONTINUE.md\n```md\n" + cont.slice(0, 4000) + "\n```")
        if (tail.trim()) {
          context.push("#### Latest session log (this machine)\n```md\n" + tail.slice(-2000) + "\n```")
        }
        output.context.push(context.join("\n"))
      } catch (err) {
        // never break compaction
      }
    },
  }
}