#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Unwedge the pad's GIP state machine so xpad's init lands.
# Ordering is load-bearing. xpad must be loaded BEFORE the device re-arrives,
# so it probes a fresh USB arrival rather than binding one already present.
# Binding an already-present device does not work; that was measured.
# This is a workaround, not a fix. It does not survive a replug or reboot.
# Usage: sudo ./recover.sh
set -uo pipefail
[ "$EUID" -eq 0 ] || { echo "needs root"; exit 2; }
SYS=""
for d in /sys/bus/usb/devices/*/; do
  [ -f "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor")$(cat "$d/idProduct")" = "0e6f0250" ] && SYS="$d" && break
done
[ -z "$SYS" ] && { echo "pad not present"; exit 2; }
DEV=$(basename "$SYS")
CONF=/etc/modprobe.d/zz-xpad-recover.conf
cleanup() { rm -f "$CONF"; modprobe xpad 2>/dev/null; }
trap cleanup EXIT

printf "blacklist xpad\ninstall xpad /bin/false\n" > "$CONF"
rmmod xpad 2>/dev/null
echo 0 > "$SYS/authorized"; sleep 2
echo 1 > "$SYS/authorized"; sleep 2
echo "pad unclaimed, resetting for 25s"
sleep 25

rm -f "$CONF"
modprobe xpad; sleep 2
echo 0 > "$SYS/authorized"; sleep 1
echo 1 > "$SYS/authorized"; sleep 3

DRV=$(readlink -f "$SYS$DEV:1.0/driver" 2>/dev/null | xargs -r basename)
echo "driver: ${DRV:-NONE}"
echo "Run ./verify.sh to confirm, pressing every control. Silence on the wire"
echo "does NOT prove success; only input reports do."
