import QtQuick
import Quickshell
import Quickshell.Io

// Agent Pet — service entry point.
//
// Owns the configuration, the event socket, the session table and the state
// machine. One transparent layer-shell window per screen is created from here.
//
// Events arrive as one JSON object per line on $XDG_RUNTIME_DIR/agent-pet/events.sock:
//   {"agent":"hermes","session":"abc","state":"working","detail":"Bash"}
// state is one of: working | waiting | done | idle
//   idle removes the session from the table.
Scope {
  id: root

  // Injected by the shell host when the property exists.
  property var shell: null
  property string omarchyPath: ""
  property var manifest: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/agent-pet"
  readonly property string socketPath: runtimeDir + "/events.sock"
  readonly property string userConfigPath: home + "/.config/agent-pet/config.json"
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))

  // ---------------------------------------------------------------- config
  property var config: ({})
  property bool ready: false
  property string configError: ""
  property bool hidden: false
  // Master switch, exposed to the bar widget and `omarchy-shell agent-pet toggle`.
  // OFF = pet never shows; ON = pet follows auto-hide (idle hides, work shows).
  property bool enabled: true
  // Set by the pet window while the user drags it (auto-hide stands down).
  property bool dragging: false

  readonly property real size: Number(config.size) || 560
  readonly property string layer: config.layer === "overlay" ? "overlay" : "top"
  readonly property real gravity: Number(config.gravity) || 1400
  readonly property real throwPower: Number(config.throwPower) || 1.0
  readonly property int sessionTtl: Number(config.sessionTtl) || 900
  // Silence from an agent that was working means it is probably gone (crashed,
  // closed, unreachable). Fall back to the resting pose rather than showing a
  // typing robot forever.
  readonly property int workingTtl: Number(config.workingTtl) || 90
  readonly property int doneHold: Number(config.doneHold) || 4
  // After a finish the pet stays on screen, waiting, for restTtl seconds
  // (default 900 = 15 min) instead of disappearing at once.
  readonly property int restTtl: Number(config.restTtl) || 900
  // Bell rings: one at once + repeats. bellRings = total rings; bellInterval
  // = seconds between repeats (default 300 = 5 min).
  readonly property int bellRings: Math.max(1, Number(config.bellRings) || 3)
  readonly property int bellInterval: Math.max(5, Number(config.bellInterval) || 300)
  property int bellRingsDone: 0
  // Last time we actually rang, so a burst of finish events (Hermes emits
  // several per turn end) rings once, not once per event.
  property double lastRingAt: 0
  // When enabled, hide the pet while no agent session is live; show it the
  // moment one starts. Set `"autoHide": false` in ~/.config/agent-pet/config.json
  // to keep the pet on screen at all times.
  readonly property bool autoHide: config.autoHide !== false
  // Bell sound: played on "done". Config `bellSound` overrides the bundled
  // assets/bell.wav (absolute path or path relative to the plugin dir); set
  // `"bellSound": "off"` to silence the bell. `bellVolume` is 0.0–1.0.
  readonly property string bellSoundPath: {
    var s = String(config.bellSound || "")
    if (s === "" || s === "off") return root.pluginDir + "/assets/bell.wav"
    return s.charAt(0) === "/" ? s : root.pluginDir + "/" + s
  }
  readonly property bool bellEnabled: String(config.bellSound || "") !== "off"
  readonly property real bellVolume: Math.max(0, Math.min(1, Number(config.bellVolume) || 0.9))

  function playBell() {
    if (!root.ready || !root.bellEnabled) return
    Quickshell.execDetached(["/usr/sbin/pw-play", "--volume", String(root.bellVolume),
      root.bellSoundPath])
  }

  function rebuildConfig() {
    if (!defaultsFile.loaded) return
    var merged = ({})
    try {
      var base = JSON.parse(defaultsFile.text())
      for (var k in base) merged[k] = base[k]
    } catch (e) {
      configError = String(e)
      console.warn("[agent-pet] built-in config is not valid JSON:", e)
    }
    if (userFile.loaded) {
      var text = userFile.text()
      if (text.trim() !== "") {
        try {
          var user = JSON.parse(text)
          for (var u in user) merged[u] = user[u]
        } catch (e2) {
          configError = String(e2)
          console.warn("[agent-pet] user config ignored:", e2)
        }
      }
    }
    config = merged
    ready = true
  }

  FileView {
    id: defaultsFile
    path: root.pluginDir + "/assets/config.json"
    blockLoading: true
    printErrors: false
    onLoaded: root.rebuildConfig()
  }

  FileView {
    id: userFile
    path: root.userConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.rebuildConfig()
    onLoadFailed: root.rebuildConfig()
  }

  // ------------------------------------------------------------ session table
  // key = agent + ":" + session. Kept as a fresh object on every change so QML
  // bindings that read it re-evaluate.
  property var sessions: ({})
  property string petState: "waiting"
  property string petDetail: ""
  // Reported by the window so `agent-pet state` can show where the pet is.
  property var petInfo: ({})

  readonly property var rank: ({ waiting: 3, working: 2, done: 1 })

  function handleEvent(line) {
    var ev
    try {
      ev = JSON.parse(line)
    } catch (e) {
      console.warn("[agent-pet] bad event line:", line)
      return
    }
    if (!ev || typeof ev !== "object") return

    var agent = String(ev.agent || "agent")
    var sid = String(ev.session || "default")
    var key = agent + ":" + sid
    var state = String(ev.state || "working")

    var next = ({})
    for (var k in sessions) next[k] = sessions[k]

    // "idle"/"end" (Hermes fires this on session end after a completed task)
    // means the work is over: keep the row, flip it to done so the rest
    // window and repeat bells apply. A session we never tracked does nothing.
    if (state === "idle" || state === "end") {
      if (next[key]) {
        next[key] = {
          agent: agent,
          session: sid,
          state: "done",
          detail: String(ev.detail || next[key].detail || ""),
          ts: Date.now()
        }
      }
    } else {
      next[key] = {
        agent: agent,
        session: sid,
        state: state,
        detail: String(ev.detail || ""),
        ts: Date.now()
      }
    }

    // A finish (turn over, session end, failure) rings the bell: once now,
    // then again every bellInterval until bellRings total have rung. Hermes
    // emits several finish events per turn end (agent_loop_stopped,
    // subagent_stop, on_session_end), so absorb a burst: only the first
    // finish within 3 s starts the ring sequence.
    if (state === "done" || state === "error" || state === "end" || state === "idle") {
      if (Date.now() - root.lastRingAt > 3000) {
        root.bellRingsDone = 1
        root.playBell()
        root.lastRingAt = Date.now()
        bellTimer.stop()
        bellTimer.start()
      }
    }

    sessions = next
    recompute()
  }

  // Highest priority wins; ties go to the most recent event. A finished turn
  // holds the done pose for doneHold, then keeps the pet visible and waiting
  // for restTtl (so he stays after a completed task), and only then hides.
  function recompute() {
    var now = Date.now()
    var best = null
    var finished = false
    var resting = false

    for (var k in sessions) {
      var s = sessions[k]
      var age = now - s.ts
      if (age > sessionTtl * 1000) continue
      var state = s.state === "error" ? "done" : s.state
      if (state === "done") {
        if (age <= doneHold * 1000) finished = true
        if (age <= restTtl * 1000) resting = true
        continue
      }
      if (state === "working" && age > workingTtl * 1000) continue
      var r = rank[state] || 0
      if (r === 0) continue
      if (!best || r > best.r || (r === best.r && s.ts >= best.ts)) {
        best = { r: r, ts: s.ts, state: state, detail: s.detail }
      }
    }

    var state = "waiting"
    if (finished) state = "done"
    else if (best) state = best.state
    var detail = best ? best.detail : ""
    if (state !== petState) petState = state
    if (detail !== petDetail) petDetail = detail

    // ------------------------------------------------------------ visibility
    // Auto-hide: show while agent-y work is live, or while resting off a
    // recently finished session (restTtl). OFF switch pins it hidden; a
    // mid-drag pet stays put.
    if (!root.enabled) {
      root.hidden = true
    } else if (root.dragging) {
      // leave it where it is; next tick after release re-evaluates
    } else {
      root.hidden = !(best !== null || resting || finished)
    }
  }

  // Repeats the bell every bellInterval up to bellRings total rings.
  Timer {
    id: bellTimer
    interval: root.bellInterval * 1000
    repeat: false
    onTriggered: {
      if (root.bellRingsDone < root.bellRings) {
        root.bellRingsDone += 1
        root.playBell()
        bellTimer.start()
      }
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.ready
    onTriggered: root.recompute()
  }

  // ---------------------------------------------------------------- socket
  // The directory has to exist (0700) before the server starts listening.
  Process {
    id: mkRuntime
    command: ["mkdir", "-p", "-m", "700", root.runtimeDir]
    Component.onCompleted: running = true
    onExited: function(code) {
      if (code !== 0) console.warn("[agent-pet] could not create " + root.runtimeDir)
      eventServer.active = true
    }
  }

  SocketServer {
    id: eventServer
    path: root.socketPath
    handler: Socket {
      parser: SplitParser {
        onRead: line => root.handleEvent(line)
      }
    }
  }

  // ---------------------------------------------------------------- IPC
  // omarchy-shell agent-pet state | play <waiting|working|done> | toggle | send <json>
  // Functions the service exposes directly (used by the bar widget too):
  function toggle() {
    root.enabled = !root.enabled
    root.recompute()
    return root.enabled ? "enabled" : "disabled"
  }

  function setEnabled(on) {
    root.enabled = !!(on === true || on === "on" || on === "true" || on === "1")
    root.recompute()
    return root.enabled ? "enabled" : "disabled"
  }

  IpcHandler {
    target: "agent-pet"

    function state(): string {
      return JSON.stringify({
        ready: root.ready,
        enabled: root.enabled,
        hidden: root.hidden,
        autoHide: root.autoHide,
        configError: root.configError,
        petState: root.petState,
        detail: root.petDetail,
        pet: root.petInfo,
        socket: root.socketPath,
        sessions: root.sessions
      })
    }

    function play(name: string): string {
      root.handleEvent(JSON.stringify({ agent: "ipc", session: "play", state: name }))
      return root.petState
    }

    function send(json: string): string {
      root.handleEvent(json)
      return root.petState
    }

    function toggle(): string {
      return root.toggle()
    }

    function setEnabled(on: string): string {
      return root.setEnabled(on)
    }

    function reload(): string {
      root.rebuildConfig()
      return "ok"
    }
  }

  // ---------------------------------------------------------------- windows
  function screenName() {
    var screens = Quickshell.screens
    var want = String(config.screen || "")
    if (want) {
      for (var i = 0; i < screens.length; i++) {
        if (screens[i].name === want) return want
      }
    }
    return screens.length ? screens[0].name : ""
  }

  Variants {
    model: root.ready ? Quickshell.screens.filter(s => s.name === root.screenName()) : []

    PetWindow {
      required property var modelData
      screen: modelData
      service: root
    }
  }
}
