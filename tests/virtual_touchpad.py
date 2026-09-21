"""A virtual touchpad: real two-finger swipes through libinput and Hyprland, for testing.

Needs write access to /dev/uinput and python-evdev. It warps the real cursor, so run it
when nobody is using the desktop.

    vpad.py swipe X Y DX [DY] [ms]   pointer to (X,Y) logical, then two fingers travel DX,DY (mm)
    vpad.py probe                    print the daemon's gesture state
"""
import json, subprocess, sys, time
from evdev import UInput, AbsInfo, ecodes as e

RES = 30                    # units per mm
W, H = 100 * RES, 66 * RES  # a 100 x 66 mm pad

def make():
    caps = {
        e.EV_KEY: [e.BTN_LEFT, e.BTN_TOOL_FINGER, e.BTN_TOOL_DOUBLETAP, e.BTN_TOOL_TRIPLETAP, e.BTN_TOUCH],
        e.EV_ABS: [
            (e.ABS_X, AbsInfo(0, 0, W, 0, 0, RES)),
            (e.ABS_Y, AbsInfo(0, 0, H, 0, 0, RES)),
            (e.ABS_MT_SLOT, AbsInfo(0, 0, 4, 0, 0, 0)),
            (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0)),
            (e.ABS_MT_POSITION_X, AbsInfo(0, 0, W, 0, 0, RES)),
            (e.ABS_MT_POSITION_Y, AbsInfo(0, 0, H, 0, 0, RES)),
        ],
    }
    return UInput(caps, name="omapager-test-touchpad", input_props=[e.INPUT_PROP_POINTER, e.INPUT_PROP_BUTTONPAD])

def warp(x, y):
    subprocess.run(["hyprctl", "dispatch", "hl.dsp.cursor.move({x=%d,y=%d})" % (x, y)], capture_output=True)

def fingers(ui, pts, ids):
    for slot, (x, y) in enumerate(pts):
        ui.write(e.EV_ABS, e.ABS_MT_SLOT, slot)
        if ids is not None:
            ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, ids[slot])
        ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, int(x))
        ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, int(y))
    ui.write(e.EV_ABS, e.ABS_X, int(pts[0][0]))
    ui.write(e.EV_ABS, e.ABS_Y, int(pts[0][1]))

def swipe(ui, dx_mm, dy_mm, ms=260, steps=26):
    x0, y0 = W * 0.45, H * 0.5
    pts = [(x0, y0), (x0 + 12 * RES, y0 - 3 * RES)]
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, 0); ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, 101)
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, int(pts[0][0])); ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, int(pts[0][1]))
    ui.write(e.EV_ABS, e.ABS_X, int(pts[0][0])); ui.write(e.EV_ABS, e.ABS_Y, int(pts[0][1]))
    ui.write(e.EV_KEY, e.BTN_TOUCH, 1); ui.write(e.EV_KEY, e.BTN_TOOL_FINGER, 1); ui.syn(); time.sleep(0.012)
    ui.write(e.EV_ABS, e.ABS_MT_SLOT, 1); ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, 102)
    ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, int(pts[1][0])); ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, int(pts[1][1]))
    ui.write(e.EV_KEY, e.BTN_TOOL_FINGER, 0); ui.write(e.EV_KEY, e.BTN_TOOL_DOUBLETAP, 1); ui.syn()
    time.sleep(0.03)
    for i in range(1, steps + 1):
        f = i / steps
        moved = [(px + dx_mm * RES * f, py + dy_mm * RES * f) for px, py in pts]
        fingers(ui, moved, None)
        ui.syn()
        time.sleep(ms / 1000 / steps)
    for slot in range(2):
        ui.write(e.EV_ABS, e.ABS_MT_SLOT, slot)
        ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
    ui.write(e.EV_KEY, e.BTN_TOOL_DOUBLETAP, 0)
    ui.write(e.EV_KEY, e.BTN_TOUCH, 0)
    ui.syn()

def probe():
    d = json.loads(subprocess.run(["omarchy-shell", "omapager", "probe"], capture_output=True, text=True).stdout)
    keys = ["toasts", "swipeKeys", "thrown", "missedOpen", "missedShown", "missedCount", "missedScroll", "lastWheel"]
    return {k: d.get(k) for k in keys}

if __name__ == "__main__":
    if sys.argv[1] == "probe":
        print(probe()); sys.exit()
    x, y, dx = int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
    dy = float(sys.argv[5]) if len(sys.argv) > 5 else 0
    ms = int(sys.argv[6]) if len(sys.argv) > 6 else 260
    ui = make()
    time.sleep(0.8)          # let libinput pick it up
    warp(x, y); time.sleep(0.25)
    swipe(ui, dx, dy, ms)
    time.sleep(0.6)
    print(probe())
    ui.close()
