// Two fingers on a touchpad, read as intent.
//
// A two-finger swipe reaches a layer surface as nothing more than a stream of
// scroll deltas with a stop at the end. This turns that stream into the two
// things a deck can do with it: carry cards sideways (and maybe throw them
// away), or scroll the deck. Pure - deltas in, decisions out - so the feel can
// be tested without a compositor or a hand.
.pragma library

// Travel before the gesture commits to an axis. Fingers never land perfectly
// straight: without a dead zone, a vertical scroll that wobbles a pixel
// sideways starts dragging a card, and a swipe that dips starts scrolling.
var LOCK = 8

// How far a card has to be carried to be thrown when the fingers lift, as a
// fraction of its width. A third is past "I nudged it" and well short of "I
// had to drag it off the screen".
var DISMISS = 0.35

// A fast, short flick throws too - the way people actually dismiss things -
// but it still has to travel somewhere, or a twitch at lift-off would count.
var FLICK = 0.9        // px per ms at release
var FLICK_MIN = 24     // px

// No event for this long means the fingers are up. The compositor sends an
// explicit stop, but not every path delivers one, and a card must never be
// left hanging half way off the deck.
var IDLE = 160

function start(now) {
  return { axis: "", dx: 0, dy: 0, x: 0, t: now, vx: 0 }
}

// One delta, in the direction the fingers moved. Returns the new state; the
// old one is left alone.
function feed(s, dx, dy, now) {
  var n = { axis: s.axis, dx: s.dx + dx, dy: s.dy + dy, x: s.x, t: now, vx: s.vx }
  if (!n.axis && (Math.abs(n.dx) >= LOCK || Math.abs(n.dy) >= LOCK))
    n.axis = Math.abs(n.dx) > Math.abs(n.dy) ? "x" : "y"
  if (n.axis === "x") {
    // Carried from where the axis locked, not from where the fingers landed:
    // counting the dead zone makes the card jump by it the moment it starts
    // to move.
    n.x = s.axis === "x" ? s.x + dx : n.dx - (n.dx > 0 ? LOCK : -LOCK)
    // Velocity is smoothed and only moves on real travel: the stop at the end
    // carries a zero delta, and letting it in would read every release as the
    // fingers having come to rest.
    if (dx !== 0) {
      var v = dx / Math.max(1, now - s.t)
      n.vx = s.vx ? s.vx * 0.5 + v * 0.5 : v
    }
  }
  return n
}

// What is drawn for a carry of x. Towards the edge the card follows the
// fingers exactly. Away from it there is nowhere for a notification to go, so
// it gives a little and resists - moving at all says "yes, this can be swiped",
// and resisting says "not this way".
function drawn(x) {
  return x >= 0 ? x : -Math.min(Math.sqrt(-x) * 3, 36)
}

// Whether lifting the fingers now throws what they are carrying.
function throws(s, width) {
  if (!s || s.axis !== "x") return false
  if (s.x >= width * DISMISS) return true
  return s.vx >= FLICK && s.x >= FLICK_MIN
}

// How long the throw takes from where the card is: faster fingers, faster
// exit, but never so fast it reads as the card vanishing.
function throwDuration(s, width) {
  var left = Math.max(0, width - Math.max(0, s ? s.x : 0))
  var speed = Math.max(1.2, s ? s.vx : 0)
  return Math.round(Math.max(90, Math.min(220, left / speed)))
}
