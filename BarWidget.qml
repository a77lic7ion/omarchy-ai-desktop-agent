import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Agent Pet — bar on/off switch.
//
// One robot button in the status area. It looks up the Agent Pet service (the
// same one that runs the pet window) and calls setEnabled() on it, so the
// switch and the pet always agree:
//
//   ON  (lit blue)  pet follows auto-hide: hidden while idle, shown while working
//   OFF (grey)      pet pinned out of sight entirely
//
// Click always toggles: via the service object when it is current, otherwise
// through the omarchy-shell IPC channel as a fallback (the widget may briefly
// hold a stale reference across a plugin hot-reload).
BarWidget {
  id: root
  moduleName: "shaun.agent-pet"

  property var shell: null
  property var service: null

  function findService() {
    var api = root.shell || (root.bar && root.bar.shell) || null
    if (api && typeof api.serviceFor === "function") {
      var s = api.serviceFor(root.moduleName)
      if (s) return s
    }
    return null
  }

  function refreshService() {
    var found = root.findService()
    if (found && found !== root.service) root.service = found
  }

  function togglePet() {
    // Favour a live service object, but never depend on it: hot reloads can
    // leave the widget holding a stale instance, so fall back to the IPC.
    if (root.service && typeof root.service.setEnabled === "function") {
      root.service.setEnabled(!root.service.enabled)
    } else {
      root.bar.run("omarchy-shell -q agent-pet toggle")
      Qt.callLater(root.refreshService)
    }
  }

  readonly property bool petEnabled: root.service ? root.service.enabled : true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: refreshService()
  onShellChanged: refreshService()
  Component.onCompleted: refreshService()

  // Always poll: the service can be replaced by a plugin reload, and a stale
  // reference must not live forever (it makes clicks silently no-op).
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      root.refreshService()
      // Detect a stale instance (old QML type without the control methods)
      // and drop it so the next click uses the IPC fallback path.
      if (root.service && typeof root.service.setEnabled !== "function")
        root.service = null
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf544" // fa-robot
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    // Lit (accent) = enabled; grey = disabled. Missing service defaults to
    // enabled so the button never looks broken.
    active: root.service ? root.service.enabled : true
    tooltipText: root.service
      ? "Agent Pet: " + (root.service.enabled ? "on" : "off") + " — click to " + (root.service.enabled ? "hide" : "show")
      : "Agent Pet — service starting"
    onPressed: function (mouseButton) {
      if (mouseButton !== Qt.LeftButton) return
      root.togglePet()
    }
  }
}
