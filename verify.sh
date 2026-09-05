#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Verify Victrix Gambit Prime (0e6f:0250) input support. See SPEC.md §5, §8.
# Usage: ./verify.sh [capture_seconds]   (default 30)
# Exit 0 = pad emits input (AC2 pass). Exit 1 = no input. Exit 2 = not found.
set -uo pipefail
VID_PID="0e6f:0250"; SECS="${1:-30}"

echo "=== environment ==="
echo "kernel:      $(uname -r)"
echo "kernel-devel: $(rpm -q kernel-devel-"$(uname -r)" 2>&1 | head -1)"
echo "secureboot:  $(mokutil --sb-state 2>&1 | head -1)"
echo "dkms:"; dkms status 2>&1 | sed 's/^/  /' | head; [ -z "$(dkms status 2>/dev/null)" ] && echo "  (none registered)"
echo "modules:     $(lsmod | grep -E '^(xone|xpad)' | awk '{print $1}' | tr '\n' ' ')"

echo "=== device ==="
lsusb -d "$VID_PID" || { echo "NOT PRESENT"; exit 2; }
# resolve sysfs path + bound driver without hardcoding bus position (it moves)
SYS=""
for d in /sys/bus/usb/devices/*/; do
  [ -f "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor")$(cat "$d/idProduct")" = "0e6f0250" ] && SYS="$d" && break
done
echo "sysfs:  ${SYS:-unresolved}"
[ -n "$SYS" ] && echo "driver: $(basename "$(readlink -f "${SYS}"*:1.0/driver 2>/dev/null)")"
# xone: gip0 without gip0.0 = driver fine, pad silent (SPEC.md §15)
if [ -d "${SYS}"*:1.0/gip0 ] && ! ls -d "${SYS}"*:1.0/gip0/gip0.* >/dev/null 2>&1; then
  echo "gip:    gip0 present, NO CLIENT - pad is powered off. Press the Xbox button and re-run."; exit 2
fi

# resolve event node by id-link, not a fixed eventN (it moves across replug)
EV=$(readlink -f /dev/input/by-id/*Victrix*event-joystick 2>/dev/null | head -1)
echo "evdev:  ${EV:-NOT FOUND}"
[ -z "$EV" ] && exit 2
echo "access: $(test -r "$EV" && echo readable || echo NOT-READABLE)"

echo "=== exclusive-grab confounder check ==="
python3 -c "
import fcntl,os,sys
fd=os.open('$EV',os.O_RDONLY)
try: fcntl.ioctl(fd,0x40044590,1); fcntl.ioctl(fd,0x40044590,0); print('  no grab held - capture is valid')
except OSError as e: print(f'  GRABBED ({e.strerror}) - zero-event result would be INVALID'); sys.exit(1)
os.close(fd)"

echo "=== capturing ${SECS}s: press every button, both sticks, both triggers, dpad ==="
python3 - "$EV" "$SECS" <<'PY'
import struct,select,time,os,sys
p,secs=sys.argv[1],int(sys.argv[2]); fmt='llHHi'; sz=struct.calcsize(fmt)
fd=os.open(p,os.O_RDONLY|os.O_NONBLOCK); n=0; seen=set(); end=time.time()+secs
while time.time()<end:
    if not select.select([fd],[],[],1.0)[0]: continue
    try:
        while True:
            d=os.read(fd,sz)
            if len(d)<sz: break
            _,_,t,c,v=struct.unpack(fmt,d)
            if t: n+=1; seen.add((t,c))
    except BlockingIOError: pass
axes={c for t,c in seen if t==3}; btns={c for t,c in seen if t==1}
print(f"  events={n} axes={sorted(axes)} buttons={len(btns)}")
need={0,1,3,4,2,5,16,17}   # X Y RX RY Z RZ HAT0X HAT0Y
missing=need-axes
if n==0: print("  RESULT: FAIL - no input (SPEC.md §3 symptom unchanged)"); sys.exit(1)
print(f"  RESULT: PASS - pad is emitting input" + (f" (axes not exercised: {sorted(missing)})" if missing else " (all axes seen)"))
PY
