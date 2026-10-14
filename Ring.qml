import QtQuick
import qs.Commons

// A card's border, laid over its BorderSurface (shaders/ring.frag). The
// shell draws a gradient or uneven border as a vector ring, and at a
// fractional display scale its pieces overlap where they meet: a 1 px border
// came out brighter and heavier for a stretch past each corner. A thick
// border hides that; a thin one shows it plainly. This draws the same band,
// the same gradient, as one even line.
//
// It takes the borders the shell would draw that way - a gradient of up to
// four colours, or uneven sides. Anything else it leaves to the surface:
// give the surface `surfaceSpec`, which is the spec itself when the ring
// is not drawing, and the same widths with nothing drawn when it is.
ShaderEffect {
  id: ring

  property var spec: Border.none()
  property real radius: 0

  readonly property var _gradient: spec && spec.gradient ? spec.gradient
                                                         : ({ colors: [], angle: 0, enabled: false })
  readonly property var _colors: _gradient.enabled ? _gradient.colors
                                                   : [Border.color(spec)]
  readonly property bool drawing: !!spec && Border.needsOverlay(spec) && _colors.length >= 1
                                  && _colors.length <= 4
  readonly property var surfaceSpec: drawing
      ? { color: "transparent", widths: spec.widths,
          gradient: { colors: [], angle: 0, enabled: false } }
      : spec

  function rgba(i) {
    var c = Qt.lighter(_colors[Math.min(i, _colors.length - 1)], 1.0)
    return Qt.vector4d(c.r, c.g, c.b, c.a)
  }
  readonly property var _ends: {
    var rad = (Number(_gradient.angle) || 0) * Math.PI / 180
    var dx = Math.cos(rad), dy = Math.sin(rad)
    var w = Math.max(1, width), h = Math.max(1, height)
    var len = (Math.abs(w * dx) + Math.abs(h * dy)) / 2
    return { x1: w / 2 - dx * len, y1: h / 2 - dy * len,
             x2: w / 2 + dx * len, y2: h / 2 + dy * len }
  }

  visible: drawing && width > 0 && height > 0
  anchors.fill: parent
  z: 100000  // over the surface's own children, as the shell's ring is

  property vector2d size: Qt.vector2d(width, height)
  property vector4d widths: drawing
      ? Qt.vector4d(Border.top(spec), Border.right(spec), Border.bottom(spec), Border.left(spec))
      : Qt.vector4d(0, 0, 0, 0)
  property vector2d from: Qt.vector2d(_ends.x1, _ends.y1)
  property vector2d to: Qt.vector2d(_ends.x2, _ends.y2)
  property vector4d c0: rgba(0)
  property vector4d c1: rgba(1)
  property vector4d c2: rgba(2)
  property vector4d c3: rgba(3)
  property real stops: _colors.length
  fragmentShader: Qt.resolvedUrl("shaders/ring.frag.qsb")
}
