import QtQuick

// The pet itself: a 16:9 sprite canvas that sits on the bottom of the screen,
// is dragged around, and falls under gravity.
//
// Sprite contract (matches the clips in assets/webp/):
//   480 x 270 canvas, content 181 wide x 247 tall at x=149, feet on y=247.
//   So the visible body sits in the lower 91.5% of the box and is centred.
Item {
  id: pet

  property var service
  property real areaW: 0
  property real areaH: 0

  readonly property real boxW: service.size
  readonly property real boxH: boxW * 9 / 16
  // Distance from the bottom of the canvas to the desk legs.
  readonly property real groundPad: boxH * (270 - 247) / 270
  // How far above the floor to stand, e.g. to clear a dock.
  readonly property real bottomMargin: Number(service.config.bottomMargin) || 0
  readonly property real floorY: Math.max(0, areaH - boxH + groundPad - bottomMargin)

  // Same sum as floorY, but computed from primitives on purpose: reading a
  // derived binding inside an on<Property>Changed handler can hand back the
  // value from before the change, which leaves the pet clipped off-screen.
  function floorNow() {
    return Math.max(0, areaH - boxH + groundPad - bottomMargin)
  }

  readonly property string clipName: service.petState === "working" ? "working"
                               : service.petState === "done" ? "done" : "waiting"

  width: boxW
  height: boxH

  property bool dragging: false
  property real vy: 0
  property real vx: 0
  property real dragVX: 0
  property real dragVY: 0
  property real lastX: 0
  property real lastY: 0
  property double lastT: 0
  property bool placed: false

  AnimatedImage {
    id: sprite
    anchors.fill: parent
    source: Qt.resolvedUrl("assets/webp/" + pet.clipName + ".webp")
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    cache: false
    smooth: true
    playing: true
  }

  // Only the body is interactive; the transparent canvas stays click-through.
  Item {
    id: hitArea
    x: pet.width * (149 / 480)
    y: 0
    width: pet.width * (181 / 480)
    height: pet.height * (247 / 270)
  }

  // Exposed so the window can mask input to the body only.
  readonly property Item hitAreaItem: hitArea

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    drag.target: pet
    drag.axis: Drag.XAndYAxis
    drag.minimumX: -pet.width * 0.45
    drag.maximumX: pet.areaW - pet.width * 0.55
    drag.minimumY: 0
    drag.maximumY: pet.floorY

    onPressed: mouse => {
      pet.dragging = true
      pet.service.dragging = true
      pet.vx = 0
      pet.vy = 0
      pet.dragVX = 0
      pet.dragVY = 0
      pet.lastX = pet.x
      pet.lastY = pet.y
      pet.lastT = Date.now()
    }

    onPositionChanged: mouse => {
      if (!pet.dragging) return
      var now = Date.now()
      var dt = Math.max(1, now - pet.lastT) / 1000
      pet.dragVX = (pet.x - pet.lastX) / dt
      pet.dragVY = (pet.y - pet.lastY) / dt
      pet.lastX = pet.x
      pet.lastY = pet.y
      pet.lastT = now
    }

    onReleased: {
      pet.dragging = false
      pet.service.dragging = false
      var p = pet.service.throwPower
      pet.vx = Math.max(-2600, Math.min(2600, pet.dragVX)) * p
      pet.vy = Math.max(-2600, Math.min(2600, pet.dragVY)) * p
      var f = pet.floorNow()
      if (pet.y > f) pet.y = f
    }
  }

  Timer {
    interval: 16
    repeat: true
    running: true
    onTriggered: pet.step(interval / 1000)
  }

  function clampX() {
    var minX = -pet.width * 0.45
    var maxX = pet.areaW - pet.width * 0.55
    if (pet.x < minX) {
      pet.x = minX
      pet.vx = -pet.vx * 0.45
    } else if (pet.x > maxX) {
      pet.x = maxX
      pet.vx = -pet.vx * 0.45
    }
  }

  function step(dt) {
    if (!placed) return
    if (pet.dragging) return

    pet.vy += pet.service.gravity * dt
    pet.y += pet.vy * dt

    var f = pet.floorNow()
    if (pet.y >= f) {
      pet.y = f
      if (Math.abs(pet.vy) > 220) {
        pet.vy = -pet.vy * 0.35
      } else {
        pet.vy = 0
      }
    }
    if (pet.y < 0) {
      pet.y = 0
      pet.vy = -pet.vy * 0.3
    }

    if (pet.vx !== 0) {
      pet.x += pet.vx * dt
      pet.vx *= Math.pow(0.02, dt)
      if (Math.abs(pet.vx) < 12) pet.vx = 0
      clampX()
    }
  }

  // Place on first real geometry, and keep him on screen when the area changes.
  onAreaWChanged: place()
  onAreaHChanged: place()

  function place() {
    if (areaW <= 0 || areaH <= 0) return
    var f = floorNow()
    if (!placed) {
      var startX = Number(service.config.startX)
      if (isNaN(startX)) startX = 0.5
      pet.x = (areaW - boxW) * startX
      pet.y = f
      placed = true
    } else {
      pet.y = Math.min(pet.y, f)
    }
    clampX()
  }

  Component.onCompleted: place()

  // The visible body in window coordinates, for hit tests and debugging.
  function bodyRect() {
    return {
      x: pet.x + pet.width * (149 / 480),
      y: pet.y,
      w: pet.width * (181 / 480),
      h: pet.height * (247 / 270)
    }
  }
}
