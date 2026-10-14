import QtQuick

// The layer.effect half of the motion blur (see MotionTrack.qml): the layer's
// texture drawn as `copies` copies stepped back along the frame's movement,
// each at 1/(i+1) over the ones before it so all of them weigh the same.
// One copy is the item drawn as it is.
Item {
  id: smear
  property variant source
  property real dx: 0          // in this item's own (unscaled) pixels
  property real dy: 0
  property int copies: 1

  Repeater {
    model: smear.copies
    ShaderEffect {
      required property int index
      readonly property variant source: smear.source
      readonly property real back: (smear.copies - 1 - index) / Math.max(1, smear.copies - 1)
      width: smear.width
      height: smear.height
      x: -smear.dx * back
      y: -smear.dy * back
      opacity: 1 / (index + 1)
    }
  }
}
