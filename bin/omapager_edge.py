"""The right-edge swipe, read from the touchpad itself.

Two fingers that come onto the touchpad over its right-hand edge and travel
left pull in what you missed - the same gesture that opens Notification
Center on a Mac, including that the panel follows the fingers the whole way. It has to be read from the device: by the time the compositor turns
fingers into scroll events, where on the pad they started is gone.

Read-only and passive. Nothing is grabbed, so the same fingers still scroll
whatever is under the pointer; this only watches.
"""
import fcntl
import os
import struct

EV_SYN, EV_ABS = 0x00, 0x03
SYN_REPORT = 0
ABS_MT_SLOT = 0x2F
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39

EVENT = struct.Struct("llHHi")          # struct input_event on 64-bit
ABSINFO = struct.Struct("iiiiii")       # value, minimum, maximum, fuzz, flat, resolution


def eviocgabs(axis):
    return (2 << 30) | (ABSINFO.size << 16) | (ord("E") << 8) | (0x40 + axis)


class EdgeSwipe:
    """Fingers in, progress out. Pure: no device, no clock of its own.

    The gesture is followed, not just recognised: the missed notifications
    slide in under the fingers, so this reports how far they have come the
    whole way, the way a Mac does. Messages, one per line:

        begin              two fingers came on at the edge and are moving in
        move <p>           p = leftward travel as a share of the pad's width
        end <p> <v>        fingers up; v = speed at release, widths per second
    """

    # How much of the pad counts as its right edge. Fingers that start off
    # the pad and slide on are first seen here, already moving; a Mac's strip
    # is narrow too. Wider, and an ordinary two-finger scroll that happens to
    # start on the right-hand side of the pad begins to count.
    EDGE = 0.09
    # Travel before anything moves on screen. Two fingers resting on the edge
    # while you think are not a request.
    START = 0.015
    # A scroll down the edge of a page is not a swipe. Decided early, while
    # the travel is still small, so a page scroll never pulls the panel.
    DRIFT = 0.05
    # Fingers that sit on the edge this long without moving in are resting
    # there, not swiping.
    WINDOW = 0.8          # seconds

    def __init__(self, x_min, x_max, y_min=0, y_max=0):
        self.x_min, self.x_max = x_min, x_max
        self.width = max(1, x_max - x_min)
        self.y_span = max(1, y_max - y_min) if y_max > y_min else self.width
        self.slots = {}
        self.slot = 0
        self.armed = None       # (start_x, start_y, start_time) once the fingers land on the edge
        self.begun = False
        self.spent = False      # finished, or ruled out, until every finger lifts
        self.last = (0.0, 0.0)  # (progress, time) of the last frame
        self.speed = 0.0
        self.sent = None

    def feed(self, etype, code, value, now):
        """One input event. Returns a list of messages, possibly empty."""
        if etype == EV_ABS:
            if code == ABS_MT_SLOT:
                self.slot = value
            elif code == ABS_MT_TRACKING_ID:
                if value < 0:
                    self.slots.pop(self.slot, None)
                else:
                    self.slots[self.slot] = {"x": None, "y": None}
            elif code in (ABS_MT_POSITION_X, ABS_MT_POSITION_Y):
                finger = self.slots.get(self.slot)
                if finger is not None:
                    finger["x" if code == ABS_MT_POSITION_X else "y"] = value
            return []
        if etype == EV_SYN and code == SYN_REPORT:
            return self._frame(now)
        return []

    def _finish(self):
        out = []
        if self.begun:
            out.append("end %.4f %.3f" % (max(0.0, self.last[0]), self.speed))
        self.armed, self.begun, self.speed, self.sent = None, False, 0.0, None
        return out

    def _frame(self, now):
        placed = [f for f in self.slots.values() if f["x"] is not None and f["y"] is not None]
        count = len(self.slots)

        if count == 0:
            out = self._finish()
            self.spent = False
            return out
        if self.spent:
            return []
        if count != 2:
            # A third finger is a different gesture, and a finger lifting
            # ends this one: both are the fingers letting go of the panel.
            if self.armed is not None or count > 2:
                self.spent = True
                return self._finish()
            return []
        if len(placed) < 2:
            return []

        x = sum(f["x"] for f in placed) / 2
        y = sum(f["y"] for f in placed) / 2
        if self.armed is None:
            # The rightmost finger is on the edge strip. Two fingers side by
            # side cannot both fit on a narrow strip, and requiring it would
            # make the gesture a matter of luck.
            if max(f["x"] for f in placed) >= self.x_max - self.EDGE * self.width:
                self.armed = (x, y, now)
                self.last = (0.0, now)
            else:
                self.spent = True
            return []

        start_x, start_y, start_time = self.armed
        progress = (start_x - x) / self.width
        drift = abs(y - start_y) / self.y_span
        out = []
        if not self.begun:
            if drift > self.DRIFT and drift > progress:
                self.spent = True
                return self._finish()
            if progress < self.START:
                if now - start_time > self.WINDOW:
                    self.spent = True
                    return self._finish()
                return []
            self.begun = True
            out.append("begin")

        # Speed at release is what decides a flick, so it is smoothed over
        # the last few frames rather than taken from the last one alone.
        before, then = self.last
        dt = now - then
        if dt > 0:
            instant = (progress - before) / dt
            self.speed = self.speed * 0.5 + instant * 0.5 if self.speed else instant
        self.last = (progress, now)
        rounded = round(progress, 3)
        if rounded != self.sent:
            self.sent = rounded
            out.append("move %.4f" % progress)
        return out


def axis_range(fd, axis):
    info = ABSINFO.unpack(fcntl.ioctl(fd, eviocgabs(axis), bytes(ABSINFO.size)))
    return info[1], info[2]


def watch(path, emit):
    """Read `path` until it goes away, calling emit() for every message."""
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    try:
        x_min, x_max = axis_range(fd, ABS_MT_POSITION_X)
        y_min, y_max = axis_range(fd, ABS_MT_POSITION_Y)
        swipe = EdgeSwipe(x_min, x_max, y_min, y_max)
        emit("ready")
        pending = b""
        while True:
            chunk = os.read(fd, EVENT.size * 64)
            if not chunk:
                return
            pending += chunk
            whole = len(pending) - len(pending) % EVENT.size
            for offset in range(0, whole, EVENT.size):
                sec, usec, etype, code, value = EVENT.unpack_from(pending, offset)
                for message in swipe.feed(etype, code, value, sec + usec / 1e6):
                    emit(message)
            pending = pending[whole:]
    finally:
        os.close(fd)
