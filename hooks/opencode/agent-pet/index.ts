// OpenCode -> Agent Pet bridge.
//
// Lives at ~/.config/opencode/plugins/agent-pet/index.ts, which OpenCode loads
// as the server part of a plugin (root `index.ts`). No npm dependency: this is
// a plain plugin object, which is what `Plugin.define` returns anyway.
//
// One line of JSON per pet state change goes to the Omarchy shell plugin's
// socket: $XDG_RUNTIME_DIR/agent-pet/events.sock
//
// Set PET_DEBUG=1 in OpenCode's environment to log every event type to
// ~/.local/state/agent-pet/opencode-events.log (handy for tuning `classify`).

import net from "node:net"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const RUNTIME = process.env.XDG_RUNTIME_DIR || "/tmp"
const SOCKET = path.join(RUNTIME, "agent-pet", "events.sock")
const DEBUG = process.env.PET_DEBUG === "1"
const LOG = path.join(os.homedir(), ".local/state/agent-pet/opencode-events.log")

// --------------------------------------------------------------------- socket
// One long-lived connection, retried lazily: if the shell is restarting or the
// pet is disabled, events are simply dropped until something changes again.
let sock: net.Socket | null = null
let queue: string[] = []

function flush() {
  if (!sock) return
  while (queue.length > 0) {
    const line = queue.shift() as string
    if (!sock.write(line)) return
  }
}

function connect() {
  const s = net.connect(SOCKET)
  s.setNoDelay(true)
  s.on("connect", () => {
    sock = s
    flush()
  })
  s.on("drain", flush)
  s.on("error", () => {
    if (sock === s) sock = null
    s.destroy()
  })
  s.on("close", () => {
    if (sock === s) sock = null
  })
  return s
}

function send(payload: {
  agent: string
  session: string
  state: string
  detail?: string
}) {
  queue.push(JSON.stringify(payload) + "\n")
  if (queue.length > 64) queue = queue.slice(-64)
  if (!sock) connect()
  flush()
}

// ---------------------------------------------------------------------- debug
function debug(type: string) {
  if (!DEBUG) return
  try {
    fs.mkdirSync(path.dirname(LOG), { recursive: true })
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${type}\n`)
  } catch {}
}

// ------------------------------------------------------------------- classify
// waiting = needs the user, working = busy, done = turn over (failures ring the
// bell too). `session.status` is the authoritative source for all three.
function classify(ev: any): string | null {
  const type = String(ev?.type ?? "")
  const data = ev?.data ?? {}

  if (type === "session.status") {
    const status = String(data.status ?? "")
    if (status === "requires_action") return "waiting"
    if (status === "idle") return "done"
    if (status === "running") return "working"
    return null
  }
  if (type === "session.idle") return "done"
  if (type === "session.error" || type === "session.execution.failed") return "done"
  if (type === "permission.asked" || type === "permission.updated") return "waiting"
  if (type.startsWith("permission.")) return "working"
  if (type.startsWith("session.")) return "working"
  if (type.startsWith("message.")) return "working"
  if (type.startsWith("part.")) return "working"
  if (type.startsWith("tool.")) return "working"
  return null
}

function sessionOf(ev: any): string {
  const p = ev?.data ?? ev?.properties ?? {}
  return String(
    p.sessionID ??
      p.sessionId ??
      p.session?.id ??
      p.info?.sessionID ??
      p.info?.id ??
      "default",
  )
}

// Only report transitions: a busy turn emits hundreds of part/tool events and
// the pet already knows it is working.
const lastState = new Map<string, string>()

export default {
  id: "shaun.agent-pet",

  async setup(ctx: any) {
    const controller = new AbortController()

    // The pet keeps its session table in memory, so a shell restart forgets
    // everything. Re-assert live states now and then; `done` is deliberately
    // not repeated, or the bell would never stop ringing.
    const heartbeat = setInterval(() => {
      for (const [session, state] of lastState) {
        if (state === "done") continue
        send({ agent: "opencode", session, state })
      }
    }, 10000)

    void (async () => {
      for await (const ev of ctx.event.subscribe({ signal: controller.signal })) {
        const type = String(ev?.type ?? "")
        debug(type)
        const state = classify(ev)
        if (!state) continue
        const session = sessionOf(ev)
        if (lastState.get(session) === state) continue
        lastState.set(session, state)
        send({ agent: "opencode", session, state })
      }
    })().catch(() => {})

    return () => {
      clearInterval(heartbeat)
      controller.abort()
      sock?.destroy()
      sock = null
    }
  },
}
