// session-sync.js — zero-touch cross-device sync for opencode (Layer 2 safety net).
//
// Install once per machine so it applies everywhere:
//   cp plugins/session-sync.js ~/.config/opencode/plugins/session-sync.js
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

const HOST = hostname().split(".")[0]
const IDLE_DEBOUNCE_MS = 120_000
const START_DEBOUNCE_MS = 60_000

let lastIdleSync = 0
let lastStartSync = 0

export const SessionSync = async (ctx) => {
  const worktree = ctx.worktree ?? ctx.directory

  const log = async (level, message) => {
    const line = `[session-sync] ${message}`
    try {
      await ctx.client.app.log({ body: { service: "session-sync", level, message } })
    } catch {
      console.log(line)
    }
  }

  // Run a command string in the project worktree. Returns { ok, text }.
  const sh = async (cmd) => {
    try {
      const r = await ctx.$\`${cmd}\`.cwd(worktree)
      return { ok: true, text: r.text ? r.text() : "" }
    } catch (err) {
      const msg = err?.stderr?.text ? err.stderr.text() : err?.message ?? String(err)
      return { ok: false, text: String(msg) }
    }
  }
  const git = (cmd) => sh(`git ${cmd}`)

  const isRepo = async () => (await git("rev-parse --is-inside-work-tree")).ok
  const hasRemote = async () => (await git("remote get-url origin")).ok

  const dateStamp = () => new Date().toISOString().slice(0, 10)
  const timeStamp = () =>
    new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)

  // --- session log helpers (best-effort, never fatal) ---
  const meta = async () => {
    const date = dateStamp()
    const file = `${date}-${HOST}.md`
    const exists = await sh(`[ -f "session-logs/${file}" ] && echo yes || echo no`)
    return { date, file, exists: exists.ok && exists.text.trim() === "yes" }
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
  const syncStart = async () => {
    try {
      const now = Date.now()
      if (now - lastStartSync < START_DEBOUNCE_MS) return
      lastStartSync = now

      if (!(await isRepo())) return
      if (!(await hasRemote())) return // local-only project; nothing to sync

      const upstream = await git("rev-parse --abbrev-ref --symbolic-full-name @{upstream}")
      if (!upstream.ok) return // unborn branch / detached HEAD — skip silently
      const remote = upstream.text.trim()

      await sh("git fetch origin")
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

      if (behind > 0) {
        if (dirty) {
          const stashed = await git('stash push -m "session-sync: pre-pull"')
          if (!stashed.ok) {
            await log("warn", `start stash failed (${stashed.text.trim()}) — leaving tree alone`)
            return
          }
        }
        const pull = await git("pull --rebase")
        if (!pull.ok) {
          await log("error", `start pull failed — you may need to resolve a conflict: ${pull.text.trim()}`)
          return
        }
        if (dirty) {
          const pop = await git("stash pop")
          if (!pop.ok) {
            await log("warn", `start stash pop conflicted: ${pop.text.trim()} — run 'git stash pop' manually`)
          }
        }
        await log("info", "pulled latest changes from remote")
      }

      await ensureSessionLog()
    } catch (err) {
      await log("error", `unexpected sync-start error: ${err?.message ?? String(err)}`)
    }
  }

  // --- session idle: snapshot any uncommitted work as a wip commit ---
  const syncIdle = async () => {
    try {
      const now = Date.now()
      if (now - lastIdleSync < IDLE_DEBOUNCE_MS) return
      lastIdleSync = now

      if (!(await isRepo())) return
      if (!(await hasRemote())) return

      const status = await git("status --porcelain")
      if (!status.ok || status.text.trim() === "") return // nothing to snapshot

      const stamp = timeStamp()
      await appendSessionLog(`- [auto] wip snapshot ${stamp} (${HOST})`)

      const commit = await git(`add -A && git commit -m "wip: ${HOST} ${stamp}"`)
      if (!commit.ok) {
        await log("warn", `idle snapshot commit failed: ${commit.text.trim()}`)
        return
      }
      const push = await git("push")
      if (!push.ok) await log("warn", `idle snapshot push failed: ${push.text.trim()}`)
      await log("info", `auto-saved uncommitted work (wip: ${HOST} ${stamp})`)
    } catch (err) {
      await log("error", `unexpected idle-sync error: ${err?.message ?? String(err)}`)
    }
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
        const cont = await catFile("CONTINUE.md")
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