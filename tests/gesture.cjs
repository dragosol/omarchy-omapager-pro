// Layout counts and the touchpad gesture reader. Synthetic rows and deltas only.
const assert = require('node:assert/strict'), load = require('./js-loader.cjs');
const L = load('Layout'), G = load('Gesture');

// --- Layout: a source deck's front card carries the deck's count -----------
const rows = [
  { key: 'a1', groupKey: 'slack' }, { key: 'b1', groupKey: 'mail' },
  { key: 'a2', groupKey: 'slack' }, { key: 'a3', groupKey: 'slack' },
];
let out = L.compute(rows, { stacking: 'source', expanded: false, heightOf: () => 60 });
assert.equal(out.placements.a1.count, 3, 'front of a three-card deck says 3');
assert.equal(out.placements.a2.count, 1, 'cards behind it say nothing');
assert.equal(out.placements.b1.count, 1, 'a deck of one wears no count');
assert.equal(out.placements.a3.deck, 'slack');
assert.equal(out.placements.a3.size, 3);
out = L.compute(rows, { stacking: 'source', expanded: true, openDeck: 'slack', heightOf: () => 60 });
assert.equal(out.placements.a1.count, 3, 'still counted with the deck open');
out = L.compute(rows, { stacking: 'all', expanded: false, heightOf: () => 60 });
assert.equal(out.placements.a1.count, 3, 'all mode keeps its per-source count');
assert.equal(out.placements.a1.size, 4, 'one deck of everything');

// --- Gesture: axis lock ------------------------------------------------------
let s = G.start(0);
s = G.feed(s, 3, 1, 8);
assert.equal(s.axis, '', 'undecided inside the dead zone');
s = G.feed(s, 7, 1, 16);
assert.equal(s.axis, 'x');
assert.equal(s.x, 2, 'carried from where the axis locked, not from the landing');
s = G.feed(s, 0, 30, 24);
assert.equal(s.axis, 'x', 'a locked swipe stays a swipe when the fingers dip');

s = G.feed(G.feed(G.start(0), 1, 6, 8), 1, 6, 16);
assert.equal(s.axis, 'y', 'a vertical scroll that wobbles is still a scroll');
assert.equal(s.x, 0, 'and carries nothing');

// --- Gesture: throwing ---------------------------------------------------------
const W = 380;
function slide(total, steps, msPer) {
  let st = G.start(0), t = 0;
  for (let i = 0; i < steps; i++) { t += msPer; st = G.feed(st, total / steps, 0, t); }
  return G.feed(st, 0, 0, t + msPer);          // the stop: no travel
}
assert.equal(G.throws(slide(40, 10, 16), W), false, 'a slow short carry springs back');
assert.equal(G.throws(slide(200, 20, 16), W), true, 'past a third of the card throws');
assert.equal(G.throws(slide(60, 3, 8), W), true, 'a fast flick throws however short');
assert.equal(G.throws(slide(-200, 20, 16), W), false, 'away from the edge never throws');
assert.ok(slide(60, 3, 8).vx > 0.9, 'the stop event does not zero the velocity');
assert.equal(G.throws(G.start(0), W), false, 'no travel, no throw');

// --- Gesture: drawing -----------------------------------------------------------
assert.equal(G.drawn(120), 120, 'towards the edge the card follows exactly');
assert.ok(G.drawn(-400) >= -36 && G.drawn(-400) < 0, 'away from it the card resists, bounded');
const d = G.throwDuration(slide(200, 20, 16), W);
assert.ok(d >= 90 && d <= 220);

console.log('gesture: ok');
