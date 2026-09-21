#!/bin/bash
# Lets the logged-in user read the touchpad, for the right-edge reveal swipe.
#
#   sudo ./install-touchpad-access.sh            install
#   sudo ./install-touchpad-access.sh --remove   take it away again
#
# One udev rule, and only for devices udev itself has classified as
# touchpads: not the keyboard, not any other input. `uaccess` is the standard
# systemd-logind handoff - the same one that lets a game read a controller -
# so access follows whoever is at the seat and ends when they log out.
set -euo pipefail

RULE=/etc/udev/rules.d/70-omapager-touchpad.rules

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: it writes $RULE." >&2
  exit 1
fi

if [[ ${1:-} == --remove ]]; then
  rm -f "$RULE"
  udevadm control --reload
  udevadm trigger --subsystem-match=input --action=change
  echo "Removed $RULE."
  exit 0
fi

cat > "$RULE" <<'RULE'
# Omapager Pro: the logged-in user may read touchpads, for the edge swipe.
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHPAD}=="1", TAG+="uaccess"
RULE
chmod 644 "$RULE"
udevadm control --reload
udevadm trigger --subsystem-match=input --action=change
udevadm settle
echo "Installed $RULE. Restart the shell (omarchy-restart-shell) to start the edge swipe."
