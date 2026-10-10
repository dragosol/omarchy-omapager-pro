import QtQuick

// Pear Messages' scrolling (app/ScrollPhysics.qml there), for a scroll offset
// that is a plain property rather than a Flickable: `target[prop]` is the
// offset, 0..max, and `extent` is how tall the view showing it is.
//
// A mouse notch glides instead of jumping; a touchpad follows the fingers 1:1
// with Apple's acceleration, coasts on when they lift, and stretches past the
// ends with resistance, then springs back.
QtObject {
  id: phys

  required property QtObject target
  required property string prop
  property real max: 0
  property real extent: 1

  // ---- Apple's scroll physics (unchanged from Pear) ------------------------
  // decelRate: UIScrollView.DecelerationRate.normal, per millisecond. Speed
  //   decays exponentially, v = v0 * 0.998^t - fast start, long smooth tail.
  // bandC: the rubber-band constant from UIScrollView,
  //   f(x) = (1 - 1/(x*c/d + 1)) * d - the further past an end, the less it gives.
  // springOmega: bounce-back is a critically damped spring (damping 1.0, as in
  //   WWDC "Designing Fluid Interfaces"), 0.4 s response, carrying the flick's speed.
  // accelMax: slow stays 1:1, fast gains up to (1 + accelMax)x.
  readonly property real decelRate: 0.998
  readonly property real bandC: 0.55
  readonly property real springOmega: 2 * Math.PI / 400
  readonly property real accelMax: 1.6

  property string mode: "idle"      // idle | drag | coast | bounce
  property real vel: 0              // px/ms along the offset
  property real rawY: 0             // where the fingers put it, before the band
  property var samples: []
  property real lastT: 0
  property real glideTo: 0
  readonly property bool busy: mode !== "idle" || glide.running

  function value() { return target[prop] }
  function set(v) { target[prop] = v }

  function band(x) { var d = Math.max(1, extent); return (1 - 1 / (x * bandC / d + 1)) * d }
  function unband(y) {
    var d = Math.max(1, extent)
    return y >= d * 0.999 ? y * 50 : y * d / (bandC * (d - y))
  }
  function banded(raw) {
    if (raw < 0) return -band(-raw)
    if (raw > max) return max + band(raw - max)
    return raw
  }
  function unbanded(y) {
    if (y < 0) return -unband(-y)
    if (y > max) return max + unband(y - max)
    return y
  }

  // A mouse notch: glide to an accumulating target.
  function notch(dy) {
    mode = "idle"
    vel = 0
    var base = glide.running ? glideTo : value()
    glideTo = Math.max(0, Math.min(max, base + dy))
    glide.to = glideTo
    glide.restart()
  }

  // Fingers on the touchpad, moving the offset by dy.
  function push(dy) {
    var now = Date.now()
    if (mode !== "drag") {     // fingers down: take over from any coast
      glide.stop()
      mode = "drag"
      vel = 0
      rawY = unbanded(value())
      samples = []
      lastT = now
    }
    var dt = Math.max(1, now - lastT)
    lastT = now
    var speed = Math.abs(dy) / dt                       // px/ms
    var gain = 1 + accelMax * Math.max(0, Math.min(1, (speed - 0.35) / 2.2))
    var moved = dy * gain
    samples = samples.filter(function(s) { return now - s.t < 160 })
                     .concat([{ t: now, dy: moved }])
    rawY += moved
    set(banded(rawY))
  }

  // Fingers lifted.
  function letGo() {
    if (mode !== "drag") return
    var s = samples
    samples = []
    var v = 0
    if (s.length >= 3) {
      // speed between the first and last movement, never to "now"
      var last = s[s.length - 1].t
      var w = s.filter(function(x) { return last - x.t <= 110 })
      if (w.length >= 3) {
        var travelled = 0
        for (var k = 1; k < w.length; k++) travelled += w[k].dy
        v = travelled / Math.max(8, last - w[0].t)
      }
    }
    vel = Math.max(-8, Math.min(8, v))
    if (value() < 0 || value() > max) startBounce()
    else mode = Math.abs(vel) > 0.02 ? "coast" : "idle"
  }

  property real bounceTarget: 0
  function startBounce() {
    bounceTarget = value() < 0 ? 0 : max
    mode = "bounce"
  }

  function step(dt) {
    if (mode === "coast") {
      var decay = Math.pow(decelRate, dt)
      set(value() + vel * (decay - 1) / Math.log(decelRate))
      vel *= decay
      if (value() < 0 || value() > max) startBounce()
      else if (Math.abs(vel) < 0.01) { vel = 0; mode = "idle" }
      return
    }
    if (mode === "bounce") {
      if (bounceTarget > 0) bounceTarget = max
      // exact critically damped step: x(t) = (x0 + (v0 + w*x0) t) e^(-wt)
      var om = springOmega
      var x0 = value() - bounceTarget, v0 = vel
      var e = Math.exp(-om * dt), B = v0 + om * x0
      var x = (x0 + B * dt) * e
      vel = (v0 - om * B * dt) * e
      set(bounceTarget + x)
      if (Math.abs(x) < 0.3 && Math.abs(vel) < 0.02) {
        set(bounceTarget)
        vel = 0
        mode = "idle"
      }
    }
  }

  function stop() {
    glide.stop()
    vel = 0
    mode = "idle"
  }

  property NumberAnimation glide: NumberAnimation {
    target: phys.target; property: phys.prop
    duration: 240; easing.type: Easing.OutCubic
  }
  // Integrated per frame, not fitted to an easing curve: exact at any refresh rate.
  property FrameAnimation frames: FrameAnimation {
    running: phys.mode === "coast" || phys.mode === "bounce"
    onTriggered: phys.step(Math.min(frameTime * 1000, 34))
  }
}
