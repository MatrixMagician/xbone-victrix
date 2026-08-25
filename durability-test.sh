#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Re-enumerate the pad N times and classify each cycle as Streaming or Announce loop.
# Classification is passive: a working link goes quiet after init, a broken one
# retries POWER/LED/AUTHENTICATE forever while the pad re-ANNOUNCEs.
# Usage: sudo ./durability-test.sh [cycles]
set -uo pipefail
CYCLES="${1:-5}"; VP=0e6f0250
SYS=""
for d in /sys/bus/usb/devices/*/; do
  [ -f "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor")$(cat "$d/idProduct")" = "$VP" ] && SYS="$d" && break
done
[ -z "$SYS" ] && { echo "pad not present"; exit 2; }
DEV=$(basename "$SYS"); BUS=${DEV%%-*}
MON="/sys/kernel/debug/usb/usbmon/${BUS}u"
modprobe usbmon 2>/dev/null
[ -r "$MON" ] || { echo "need root for $MON"; exit 2; }
echo "device $DEV on bus $BUS, $CYCLES cycles"
PASS=0
for i in $(seq 1 "$CYCLES"); do
  T=$(mktemp)
  echo 0 > "$SYS/authorized"; sleep 2; echo 1 > "$SYS/authorized"
  timeout 9 cat "$MON" > "$T" 2>/dev/null &
  MONPID=$!; sleep 10; wait $MONPID 2>/dev/null
  read -r auth ann inp < <(python3 - "$T" <<'PY'
import sys
a=n=i=0
for L in open(sys.argv[1],errors='ignore'):
    if ' = ' not in L: continue
    t=L.split()
    if len(t)<4: continue
    d=L.split(' = ')[1].replace(' ','').strip()
    if len(d)<2: continue
    c=int(d[0:2],16)
    if t[3].startswith('Io') and c==0x06: a+=1
    if t[3].startswith('Ii') and c==0x02: n+=1
    if t[3].startswith('Ii') and c==0x20: i+=1
print(a,n,i)
PY
)
  drv=$(readlink -f "$SYS$DEV:1.0/driver" 2>/dev/null | xargs -r basename)
  if [ "$auth" -ge 2 ] || [ "$ann" -ge 2 ]; then
    echo "  cycle $i: BROKEN   driver=$drv auth_retries=$auth announces=$ann"
  else
    echo "  cycle $i: NO-LOOP  driver=$drv auth_retries=$auth announces=$ann (UNCONFIRMED: silence is not proof, run ./verify.sh with input)"
    PASS=$((PASS+1))
  fi
  rm -f "$T"
done
echo "RESULT: $PASS/$CYCLES cycles showed no retry loop"
echo "A retry loop proves BROKEN. Absence of one does NOT prove Streaming --"
echo "xpad also goes quiet when it gives up. Confirm with ./verify.sh."
[ "$PASS" -eq "$CYCLES" ] && exit 0 || exit 1
