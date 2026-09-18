// plugin-test.mjs — behavioural harness for plugins/session-sync.js.
// Exercises the real plugin against throwaway git projects and asserts on the
// actual git calls it makes. Run from the repo root:  node tests/plugin-test.mjs
import { spawnSync } from "node:child_process"
import { hostname } from "node:os"
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, copyFileSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HOST = hostname().split(".")[0]
const DATE = new Date().toISOString().slice(0, 10)
const HARNESS_DIR = path.dirname(fileURLToPath(import.meta.url))
const ROOT = process.env.ROE_REPO || path.resolve(HARNESS_DIR, "..")

// The repo's plugin is a plain .js (no package.json type:module); import a copy
// with a .mjs extension so node treats it as ESM.
const PLUGIN_TMP = path.join(tmpdir(), `session-sync-${process.pid}.mjs`)
copyFileSync(path.join(ROOT, "plugins/session-sync.js"), PLUGIN_TMP)
process.on("exit", () => { try { rmSync(PLUGIN_TMP, { force: true }) } catch {} })

const sh = (cmd, cwd) => {
  const r = spawnSync("bash", ["-c", cmd], { cwd, encoding: "utf8" })
  if (r.status !== 0) throw new Error(`cmd failed (${r.status}): ${cmd}\n${r.stderr}`)
  return r.stdout.trim()
}
const barred = (dir) => {
  const bare = `${dir}.bare.git`
  sh(`rm -rf -- "${bare}" && git init --bare -q "${bare}"`, dir)
  return bare
}

const { SessionSync } = await import(`file://${PLUGIN_TMP}`)

let checks = 0, failures = 0
const ok = (name, cond, detail = "") => {
  checks++
  if (cond) console.log(`  ok ${checks}  ${name}`)
  else { failures++; console.log(`FAIL ${checks}  ${name}  ${detail}`) }
}

function makeCtx(worktree, logSink, cmdLog) {
  const exec = (cwd, cmd) => {
    cmdLog.push(cmd)
    const r = spawnSync("bash", ["-c", cmd], { cwd, encoding: "utf8" })
    if (r.status !== 0 || r.error) {
      const err = {
        text: () => r.stderr ?? "",
        message: r.error ? String(r.error.message) : (r.stderr ?? "").trim(),
      }
      throw { stderr: err }
    }
    return { text: () => r.stdout ?? "" }
  }
  const $ = (strings, ...vals) => {
    let cmd = ""
    strings.forEach((s, i) => { cmd += s; if (i < vals.length) cmd += String(vals[i]) })
    return { cwd: (w) => exec(w, cmd) }
  }
  const client = {
    app: {
      log: async (payload) => {
        const { level, message } = payload.body ?? payload
        logSink.push(`[${level}] ${message}`)
      },
    },
  }
  return { worktree, client, $ }
}

const fire = async (sync, type) => { await sync.event({ event: { type } }); await new Promise((r) => setTimeout(r, 800)) }
const gitCmds = (log) => log.filter((c) => c.startsWith("git"))

// ---------------------------------------------------------------------------
const base = mkdtempSync(path.join(tmpdir(), "plantest-"))

// --- 1. NON-toolkit project: zero git calls, zero logs ---------------------
{
  const dir = path.join(base, "plain")
  mkdirSync(dir)
  sh("git init -q -b main . && git config user.email t@t && git config user.name t", dir)
  writeFileSync(path.join(dir, "file.txt"), "hi")
  sh("git add -A && git commit -qm one", dir)
  const logSink = [], cmdLog = []
  const sync = await SessionSync(makeCtx(dir, logSink, cmdLog))
  await fire(sync, "session.created"); await fire(sync, "session.idle")
  const ctxCall = { context: [] }
  await sync["experimental.session.compacting"]({ session: { messages: [] } }, ctxCall)
  ok("non-toolkit session.created/idle makes zero git calls", gitCmds(cmdLog).length === 0,
    `got: ${gitCmds(cmdLog).join(" | ")}`)
  ok("non-toolkit emits zero log lines", logSink.length === 0, `got: ${logSink.join(" | ")}`)
  ok("non-toolkit compaction injects nothing", ctxCall.context.length === 0)
}

// --- 2. Toolkit but desynced: behaves exactly like non-toolkit -------------
{
  const dir = path.join(base, "desynced")
  mkdirSync(dir)
  sh("git init -q -b main . && git config user.email t@t && git config user.name t", dir)
  mkdirSync(path.join(dir, ".opencode/state"), { recursive: true })
  writeFileSync(path.join(dir, ".opencode/toolkit"), "remote_opencode_sync\n")
  writeFileSync(path.join(dir, ".opencode/state/no-session-sync"), "")
  writeFileSync(path.join(dir, "file.txt"), "hi")
  sh("git add -A && git commit -qm one", dir)
  const logSink = [], cmdLog = []
  const sync = await SessionSync(makeCtx(dir, logSink, cmdLog))
  await fire(sync, "session.created"); await fire(sync, "session.idle")
  ok("desynced copy makes zero git calls", gitCmds(cmdLog).length === 0,
    `got: ${gitCmds(cmdLog).join(" | ")}`)
  ok("desynced copy emits no logs", logSink.length === 0)
}

// --- 3. Synced toolkit: start pulls + ensures session log ------------------
{
  const dir = path.join(base, "synced1")
  mkdirSync(dir)
  const bare = barred(dir)
  sh(`git init -q -b main . && git remote add origin "${bare}" && git config user.email t@t && git config user.name t`, dir)
  mkdirSync(path.join(dir, ".opencode"), { recursive: true })
  writeFileSync(path.join(dir, ".opencode/toolkit"), "remote_opencode_sync\n")
  writeFileSync(path.join(dir, "CONTINUE.md"), "# Status\n\nnothing yet\n")
  sh("git add -A && git commit -qm seed && git push -q -u origin HEAD", dir)
  const logSink = [], cmdLog = []
  const sync = await SessionSync(makeCtx(dir, logSink, cmdLog))
  sync.constructor // noop reference to avoid lint noise
  await fire(sync, "session.created")
  ok("start runs git fetch", cmdLog.includes("git fetch origin"))
  ok("start ran on a clean tree, no push attempted", !cmdLog.includes("git push"))
  ok("session log file was ensured",
    existsSync(path.join(dir, "session-logs", `${DATE}-${HOST}.md`)))
  // debounce: second start within the window does no extra fetch
  cmdLog.length = 0
  await fire(sync, "session.created")
  ok("start is debounced (~60s)", gitCmds(cmdLog).length === 0, `got: ${gitCmds(cmdLog).join(" | ")}`)
}

// --- 4. Idle snapshots a dirty tree as a wip commit + pushes ----------------
{
  const dir = path.join(base, "synced2")
  mkdirSync(dir)
  const bare = barred(dir)
  sh(`git init -q -b main . && git remote add origin "${bare}" && git config user.email t@t && git config user.name t`, dir)
  mkdirSync(path.join(dir, ".opencode"), { recursive: true })
  writeFileSync(path.join(dir, ".opencode/toolkit"), "remote_opencode_sync\n")
  sh("git add -A && git commit -qm seed && git push -q -u origin HEAD", dir)
  const logSink = [], cmdLog = []
  const sync = await SessionSync(makeCtx(dir, logSink, cmdLog))
  writeFileSync(path.join(dir, "work.txt"), "uncommitted work")
  await fire(sync, "session.idle")
  const log = sh('git log --oneline -1', dir)
  ok("idle created a wip: commit", log.includes("wip:"), log)
  ok("idle pushed the wip", sh("git log --oneline -1", dir) ===
    sh(`git --git-dir="${bare}" log refs/heads/main --oneline -1`, dir))
  ok("wip note appended to session log",
    sh(`tail -n1 "session-logs/${DATE}-${HOST}.md"`, dir).includes("wip snapshot"))
  ok("idle emitted an info log", logSink.some((l) => l.startsWith("[info]")))
}

// --- 5. Synced toolkit: compaction injects CONTINUE.md ----------------------
{
  const dir = path.join(base, "synced3")
  mkdirSync(dir)
  const bare = barred(dir)
  sh(`git init -q -b main . && git remote add origin "${bare}" && git config user.email t@t && git config user.name t`, dir)
  mkdirSync(path.join(dir, ".opencode"), { recursive: true })
  writeFileSync(path.join(dir, ".opencode/toolkit"), "remote_opencode_sync\n")
  writeFileSync(path.join(dir, "CONTINUE.md"), "# Status\n\ndefinitely oriented\n")
  sh("git add -A && git commit -qm seed && git push -q -u origin HEAD", dir)
  const logSink = [], cmdLog = []
  const sync = await SessionSync(makeCtx(dir, logSink, cmdLog))
  const out = { context: [] }
  await sync["experimental.session.compacting"]({}, out)
  const joined = out.context.join("\n")
  ok("compaction injects sync context w/ CONTINUE.md", joined.includes("Sync context") && joined.includes("definitely oriented"))
}

// --- 6. Synced copy, no remote at all: start is a no-op --------------------
{
  const dir = path.join(base, "noremote")
  mkdirSync(dir)
  sh("git init -q -b main . && git config user.email t@t && git config user.name t", dir)
  mkdirSync(path.join(dir, ".opencode"), { recursive: true })
  writeFileSync(path.join(dir, ".opencode/toolkit"), "remote_opencode_sync\n")
  sh("git add -A && git commit -qm seed", dir)
  const logSink = [], cmdLog = []
  const sync = await SessionSync(makeCtx(dir, logSink, cmdLog))
  await fire(sync, "session.created")
  ok("toolkit project without remote: no fetch/push/pull", !gitCmds(cmdLog).some((c) => /(fetch|push|pull|stash)/.test(c)),
    `got: ${gitCmds(cmdLog).join(" | ")}`)
}

rmSync(base, { recursive: true, force: true })

console.log(`\nplugin harness: ${checks} checks, ${failures} failed`)
process.exit(failures ? 1 : 0)