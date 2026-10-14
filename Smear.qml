import QtQuick

// The drawing half of the motion blur (see MotionTrack.qml): `face` averaged
// over `copies` copies stepped back along the frame's movement, in one shader
// pass (shaders/smear.frag). An item per copy cost a burst of item creation on
// the first frame of every exit - 2-3 dropped frames right as the card started
// to leave.
//
// Beside the item, not its layer. A layer stands in for the item the whole
// time it is on, and drawing a texture back at a fractional scale (1.6 here)
// resamples it: a primed card or heading sat there with a soft, uneven border
// - a step along the top edge, a heavy corner - before anything moved. Here
// the texture is kept warm while primed (`armed`), but the item goes on
// drawing itself, sharp, and is swapped for the smear only while it moves
// (`active`).
//
// Placed over `face`, in the same parent. The texture leaves out the face's
// own opacity, so the smear takes it over.
Item {
  id: smear
  required property Item face
  property bool armed: false
  property bool active: false
  property real dx: 0          // in the face's own (unscaled) pixels
  property real dy: 0
  property int copies: 1

  x: face.x
  y: face.y
  z: face.z
  width: face.width
  height: face.height
  opacity: face.opacity

  ShaderEffectSource {
    id: texture
    sourceItem: smear.armed || smear.active ? smear.face : null
    hideSource: smear.active
    visible: false
  }

  // The trail reaches past the face's own edge: drawn over its rectangle
  // grown by the movement. Opacity 0, not invisible, while it waits, so the
  // switch at the start of an exit only changes a number.
  ShaderEffect {
    readonly property variant source: texture
    opacity: smear.active ? 1 : 0
    x: Math.min(0, -smear.dx)
    y: Math.min(0, -smear.dy)
    width: smear.width + Math.abs(smear.dx)
    height: smear.height + Math.abs(smear.dy)
    property vector2d boxOrigin: Qt.vector2d(x, y)
    property vector2d boxSize: Qt.vector2d(width, height)
    property vector2d itemSize: Qt.vector2d(Math.max(1, smear.width), Math.max(1, smear.height))
    property vector2d delta: Qt.vector2d(smear.dx, smear.dy)
    property real count: smear.copies
    fragmentShader: Qt.resolvedUrl("shaders/smear.frag.qsb")
  }
}
