import QtQuick

// Motion blur, as hyprdrive does it: how far something moved in the last
// frame, and how many copies it takes to smear that distance with the copies
// at most 2 device pixels apart - so the smear reads as a blur, never as
// separate ghosts. Feed it a position (trackX/trackY); it runs only while
// that position is changing, and goes quiet the frame it stops.
Item {
  id: track
  visible: false
  width: 0
  height: 0

  property real trackX: 0
  property real trackY: 0
  property real dx: 0
  property real dy: 0
  property bool moving: false
  property real lastX: 0
  property real lastY: 0
  readonly property real length: Math.sqrt(dx * dx + dy * dy)
  readonly property int copies: Math.min(48, Math.ceil(length * Screen.devicePixelRatio / 2) + 1)
  // A frame that jumped further than the copies can cover at 2 px apart (a
  // dropped frame, a fast throw) gets a shorter smear, never wider gaps.
  readonly property real reach: length <= 0 ? 0
      : Math.min(1, (copies - 1) * 2 / Screen.devicePixelRatio / length)
  readonly property bool active: copies > 1

  function note() {
    if (moving) return
    lastX = trackX
    lastY = trackY
    moving = true
  }
  onTrackXChanged: note()
  onTrackYChanged: note()
  FrameAnimation {
    running: track.moving
    onTriggered: {
      var mx = track.trackX - track.lastX, my = track.trackY - track.lastY
      track.lastX = track.trackX
      track.lastY = track.trackY
      track.dx = mx
      track.dy = my
      if (mx === 0 && my === 0) track.moving = false
    }
  }
}
