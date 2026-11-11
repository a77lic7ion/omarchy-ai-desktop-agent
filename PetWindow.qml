import QtQuick
import Quickshell
import Quickshell.Wayland

// One fullscreen transparent layer-shell window per screen. Input is masked to
// the pet's body, so clicks everywhere else fall through to the desktop.
PanelWindow {
  id: win

  property var service

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  color: "transparent"
  // Normal + exclusiveZone 0: the window covers the usable area, so its bottom
  // edge is the floor the pet stands on, not underneath the bar.
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: 0
  WlrLayershell.namespace: "agent-pet"
  WlrLayershell.layer: win.service.layer === "overlay" ? WlrLayer.Overlay : WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  visible: !win.service.hidden

  Item {
    id: area
    anchors.fill: parent
  }

  Pet {
    id: pet
    service: win.service
    areaW: area.width
    areaH: area.height
    onXChanged: win.syncGeometry()
    onYChanged: win.syncGeometry()
    Component.onCompleted: win.syncGeometry()
  }

  function syncGeometry() {
    if (!win.service) return
    var r = pet.bodyRect()
    win.service.petInfo = {
      x: Math.round(pet.x),
      y: Math.round(pet.y),
      bodyX: Math.round(r.x),
      bodyY: Math.round(r.y),
      bodyW: Math.round(r.w),
      bodyH: Math.round(r.h)
    }
  }

  mask: Region { item: win.service && !win.service.hidden ? pet.hitAreaItem : null }
  onVisibleChanged: if (win.visible) win.syncGeometry()
}
