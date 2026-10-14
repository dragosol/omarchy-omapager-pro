import QtQuick

// The layer.effect half of the motion blur (see MotionTrack.qml): the layer's
// texture averaged over `copies` copies stepped back along the frame's
// movement, in one shader pass (shaders/smear.frag). An item per copy cost a
// burst of item creation on the first frame of every exit - 2-3 dropped frames
// right as the card started to leave.
//
// The shader is drawn over the card's rectangle grown by the movement, so the
// trail reaches past the card's own edge.
Item {
  id: smear
  property variant source
  property real dx: 0          // in this item's own (unscaled) pixels
  property real dy: 0
  property int copies: 1

  ShaderEffect {
    readonly property variant source: smear.source
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
