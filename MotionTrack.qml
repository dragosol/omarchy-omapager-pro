import QtQuick

// Motion blur, as hyprdrive does it, for things leaving: how far something
// moved in the last frame, and how many copies it takes to smear that
// distance with the copies at most 2 device pixels apart - so the smear reads
// as a blur, never as separate ghosts. Feed it a position (trackX/trackY); it
// runs only while that position is changing.
//
// Only on the way out. Everything that leaves goes right, into the screen
// edge - a card thrown away, a card timing out, the panel being put away -
// and nothing that arrives or rearranges does: arrivals drop in, stacks open
// downwards, the panel comes in leftwards, lists scroll. So only rightward
// movement is smeared; the rest is drawn sharp.
//
// Steady for the whole exit, not frame by frame: `smearing` latches on at the
// first rightward frame and lets go only once the thing has been still for a
// moment. Following each frame instead switched the item's layer off and on
// whenever an animation tick and a screen frame did not line up - a frame with
// no movement - and every switch reallocated the layer's buffer mid-animation,
// which is what made it choppy.
Item {
  id: track
  visible: false
  width: 0
  height: 0

  readonly property int maxCopies: 32

  property real trackX: 0
  property real trackY: 0
  property real dx: 0
  property real dy: 0
  property bool moving: false
  property bool smearing: false
  // Set by the owner when an exit is coming (a card about to time out, a
  // finger on it, the panel open and still): the layer and its effect are made
  // then, while nothing moves, instead of on the first frame of the exit -
  // where building them cost several dropped frames as the card set off.
  property bool prime: false
  // ...and kept a moment after the owner stops asking: the exit itself is
  // often what ends the reason (the panel leaving is no longer "open"), and
  // dropping the layer on that frame would rebuild it on the next.
  property bool primeHeld: false
  onPrimeChanged: { if (prime) primeHeld = true; else primeGrace.restart() }
  Timer { id: primeGrace; interval: 400; onTriggered: track.primeHeld = track.prime }
  readonly property bool layered: smearing || prime || primeHeld
  property int stillFrames: 0
  property real lastX: 0
  property real lastY: 0
  readonly property bool outward: dx > 0 && dx >= Math.abs(dy)
  readonly property real length: outward ? Math.sqrt(dx * dx + dy * dy) : 0
  readonly property int copies: smearing
      ? Math.min(maxCopies, Math.ceil(length * Screen.devicePixelRatio / 2) + 1) : 1
  // A frame that jumped further than the copies can cover at 2 px apart (a
  // dropped frame, a fast throw) gets a shorter smear, never wider gaps.
  readonly property real reach: length <= 0 ? 0
      : Math.min(1, (copies - 1) * 2 / Screen.devicePixelRatio / length)

  function note() {
    if (moving) return
    lastX = trackX
    lastY = trackY
    stillFrames = 0
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
      if (track.outward) track.smearing = true
      if (mx === 0 && my === 0) {
        // A frame or two with no movement happens mid-animation; only a
        // run of them means it has stopped.
        if (++track.stillFrames >= 4) {
          track.moving = false
          track.smearing = false
        }
      } else {
        track.stillFrames = 0
      }
    }
  }
}
