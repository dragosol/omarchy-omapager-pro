"""The right-edge reveal gesture, from synthetic touchpad frames only."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bin"))
import omapager_edge as E  # noqa: E402

W = 3000          # a pad 0..3000 wide
H = 2000


class Pad:
    def __init__(self):
        self.swipe = E.EdgeSwipe(0, W, 0, H)
        self.t = 0.0
        self.out = []
        self.ids = 0

    def ev(self, code, value):
        self.out += self.swipe.feed(E.EV_ABS, code, value, self.t)

    def frame(self, dt=0.012):
        self.t += dt
        self.out += self.swipe.feed(E.EV_SYN, E.SYN_REPORT, 0, self.t)

    def kinds(self):
        return [m.split()[0] for m in self.out if not m.startswith("move")]

    def ends(self):
        return [tuple(float(v) for v in m.split()[1:]) for m in self.out if m.startswith("end")]

    def moves(self):
        return [float(m.split()[1]) for m in self.out if m.startswith("move")]

    def down(self, slot, x, y):
        self.ev(E.ABS_MT_SLOT, slot)
        self.ids += 1
        self.ev(E.ABS_MT_TRACKING_ID, self.ids)
        self.ev(E.ABS_MT_POSITION_X, x)
        self.ev(E.ABS_MT_POSITION_Y, y)

    def move(self, slot, x, y):
        self.ev(E.ABS_MT_SLOT, slot)
        self.ev(E.ABS_MT_POSITION_X, x)
        self.ev(E.ABS_MT_POSITION_Y, y)

    def up(self, slot):
        self.ev(E.ABS_MT_SLOT, slot)
        self.ev(E.ABS_MT_TRACKING_ID, -1)

    def two(self, x0, y, dx, dy=0, steps=12, dt=0.012, gap=250):
        """Two fingers side by side, landing at x0 (the right one) and sliding."""
        self.down(0, x0 - gap, y)
        self.down(1, x0, y + 40)
        self.frame()
        for i in range(1, steps + 1):
            self.move(0, x0 - gap + dx * i // steps, y + dy * i // steps)
            self.move(1, x0 + dx * i // steps, y + 40 + dy * i // steps)
            self.frame(dt)
        self.up(0)
        self.up(1)
        self.frame()


class EdgeSwipeTest(unittest.TestCase):
    def test_from_the_edge_leftwards_is_followed_the_whole_way(self):
        p = Pad()
        p.two(W - 60, 900, -900)
        self.assertEqual(p.kinds(), ["begin", "end"])
        moves = p.moves()
        self.assertEqual(moves, sorted(moves), "progress only grows while the fingers move in")
        (progress, speed), = p.ends()
        self.assertAlmostEqual(progress, 0.3, places=2)
        self.assertGreater(speed, 1.0, "a quick swipe reports its speed")

    def test_fingers_sliding_on_from_off_the_pad(self):
        # First contact is right at the edge, already moving: that is what
        # coming on from beyond the pad looks like to the device.
        p = Pad()
        p.two(W - 5, 900, -600, gap=180)
        self.assertEqual(p.kinds(), ["begin", "end"])

    def test_starting_in_the_middle_is_just_a_scroll(self):
        p = Pad()
        p.two(W // 2, 900, -900)
        self.assertEqual(p.out, [])

    def test_rightwards_from_the_edge_never_begins(self):
        p = Pad()
        p.two(W - 60, 900, 50)
        self.assertEqual(p.out, [])

    def test_resting_on_the_edge_never_begins(self):
        p = Pad()
        p.two(W - 60, 900, -20)
        self.assertEqual(p.out, [])

    def test_a_short_pull_still_ends_so_the_panel_can_go_back(self):
        p = Pad()
        p.two(W - 60, 900, -200, steps=12, dt=0.05)
        self.assertEqual(p.kinds(), ["begin", "end"])
        (progress, speed), = p.ends()
        self.assertLess(progress, 0.1)

    def test_a_vertical_scroll_down_the_edge_is_not_a_swipe(self):
        p = Pad()
        p.two(W - 60, 300, -40, dy=1200)
        self.assertEqual(p.out, [])

    def test_three_fingers_never_count(self):
        p = Pad()
        p.down(0, W - 500, 900)
        p.down(1, W - 250, 900)
        p.down(2, W - 40, 900)
        p.frame()
        for i in range(1, 12):
            for s, x in ((0, W - 500), (1, W - 250), (2, W - 40)):
                p.move(s, x - 80 * i, 900)
            p.frame()
        self.assertEqual(p.out, [])

    def test_a_third_finger_ends_it(self):
        p = Pad()
        p.down(0, W - 300, 900)
        p.down(1, W - 50, 900)
        p.frame()
        for i in range(1, 6):
            p.move(0, W - 300 - 80 * i, 900)
            p.move(1, W - 50 - 80 * i, 900)
            p.frame()
        p.down(2, 400, 900)
        p.frame()
        self.assertEqual(p.kinds(), ["begin", "end"])

    def test_one_finger_never_counts(self):
        p = Pad()
        p.down(0, W - 40, 900)
        p.frame()
        for i in range(1, 12):
            p.move(0, W - 40 - 80 * i, 900)
            p.frame()
        self.assertEqual(p.out, [])

    def test_fingers_landing_one_after_the_other(self):
        p = Pad()
        p.down(1, W - 50, 900)
        p.frame()
        p.down(0, W - 300, 940)
        p.frame(0.03)
        for i in range(1, 12):
            p.move(0, W - 300 - 80 * i, 940)
            p.move(1, W - 50 - 80 * i, 900)
            p.frame()
        p.up(0)
        p.up(1)
        p.frame()
        self.assertEqual(p.kinds(), ["begin", "end"])

    def test_it_rearms_after_the_fingers_lift(self):
        p = Pad()
        p.two(W - 60, 900, -900)
        p.two(W - 60, 900, -900)
        self.assertEqual(p.kinds(), ["begin", "end", "begin", "end"])

    def test_the_ioctl_number(self):
        # EVIOCGABS(ABS_MT_POSITION_X), as the kernel headers spell it.
        self.assertEqual(E.eviocgabs(E.ABS_MT_POSITION_X), 0x80184575)


if __name__ == "__main__":
    unittest.main()
