<!-- SPDX-License-Identifier: GPL-2.0-only -->

# SPEC: Victrix Gambit Prime (0e6f:0250) controller support on Fedora

**Status:** Diagnosed — fix not yet applied
**Owner:** oliverh
**Created:** 2026-08-25
**Host:** neurodev

---

## 1. Problem statement

The Turtle Beach Victrix Gambit Prime wired controller (USB-C) enumerates
correctly and is detected by Steam, but produces **zero input events**. No
button, stick, trigger, or D-pad input reaches any application.

This is *not* a Steam configuration problem. It is a kernel driver problem.

---

## 2. Environment

| Item | Value |
|---|---|
| OS | Fedora release 44 (Forty Four) |
| Kernel (at diagnosis) | `7.1.9-200.fc44.x86_64` |
| Kernels installed | `7.1.7-200`, `7.1.8-200`, `7.1.9-200` (installonly_limit appears to be 3) |
| Secure Boot | **disabled** (`mokutil --sb-state`) |
| DKMS | `dkms-3.4.2-1.fc44` installed, **no modules registered** |
| akmods / kmodtool | not installed |
| `kernel-devel` | `kernel-devel-7.1.9-200.fc44.x86_64` present |
| Steam | Flatpak `com.valvesoftware.Steam` 1.0.0.85 (system install) |

### Device facts

| Item | Value |
|---|---|
| USB ID | `0e6f:0250` (Performance Designed Products) |
| Product string | `Victrix Gambit Prime Wired Controller for Xbox` |
| Serial | `00007DA7E3409C9E` |
| `bcdDevice` | 4.00 |
| USB path (as observed) | `3-2.1` |
| Interface 0 | class `ff` / subclass `0x47` / protocol `0xd0`, EP `0x81 IN` + `0x01 OUT`, 64 B, bInterval 4 |
| Interface 1 alt 1 | audio/headset, EP `0x02 OUT` (214 B) + `0x83 IN` (118 B) |
| Bound driver | `xpad` (in-tree) |
| Reported name | `Generic X-Box pad` |
| Nodes | `/dev/input/js0`, `/dev/input/event1` |

Subclass `0x47` / protocol `0xd0` identifies this as a **GIP** device
(Xbox One / Series protocol), *not* an Xbox 360-protocol pad.

---

## 3. Root cause

`xpad` has no device-table entry for `0e6f:0250`. It matches the vendor-wide
`XPAD_XBOXONE_VENDOR(0x0e6f)` catch-all, which is why it is named
`Generic X-Box pad`.

`xpad`'s generic GIP init is a fixed sequence of canned packets. It is
sufficient for older Xbox One-era PDP pads but not for this Series-generation
device. Captured with `usbmon` on bus 3 over 25 s:

```
HOST -> CONTROLLER            CONTROLLER -> HOST
  POWER          x6             STATUS        x12
  LED            x6             ANNOUNCE      x4
  AUTHENTICATE   x6
                              INPUT_REPORT (0x20):  0
```

Decoded loop:

```
xpad -> 05 20 00 01 00        POWER (power on)
xpad -> 0a 20 01 03 000114    LED
xpad -> 06 20 02 02 0100      AUTHENTICATE (hardcoded PDP packet)
pad  -> 03 20 43 04 80010000  STATUS
pad  -> 03 20 44 04 80000000  STATUS  (powers back down)
        ... xpad retries the whole sequence, indefinitely
```

Two defects in `xpad`'s GIP handling drive this:

1. **No `ACK` (0x01) is ever sent.** GIP requires the host to acknowledge
   controller messages. Unacknowledged, the pad re-announces every 500 ms —
   visible as `ANNOUNCE` with an incrementing sequence (`0x3f, 0x40, 0x41,
   0x42…`).
2. **No `IDENTIFY` (0x04) is ever sent.** `xpad` jumps straight to a
   hardcoded auth packet, which this device does not accept.

The pad therefore never leaves announce/auth and never enters the streaming
state. **Not one `INPUT_REPORT` (GIP cmd `0x20`) is ever emitted.**

### Why every other layer looks healthy

Everything above the driver is built from USB *descriptors*, which are valid.
So all of the following are green and misleading:

- `uaccess` ACL grants `oliverh` rw on `event1` / `js0`
- Capability bitmaps advertise a full pad: `ABS=3003f` (6 axes + hat),
  `KEY=7cdb…` (A/B/X/Y, LB/RB, Back/Start/Guide, L3/R3)
- Steam Flatpak sandbox is correctly provisioned (`devices=all`,
  `/run/udev:ro`)
- Steam's `controller.txt` opens the pad, applies a valid SDL mapping
  (`030086656f0e00005002000000040000`), and reserves XInput slot 0

Only the data never arrives.

### Ruled out

- Permissions / ACL — verified `user:oliverh:rw-` on both nodes
- Flatpak sandbox device access — `devices=all` + `/run/udev:ro` present
- Exclusive grab starving readers — `EVIOCGRAB` **succeeded**, so nothing
  held the device exclusively during capture
- Steam Input misconfiguration — config sets are empty (normal default),
  detection and mapping confirmed in Steam's own log
- USB autosuspend — `power/control=on`, `runtime_status=active`
- Cable/power — `bMaxPower 500mA`, clean enumeration, correct serial

---

## 4. Proposed fix

Install **`xone`**, the out-of-tree GIP driver implementing the real protocol
state machine (ACK, IDENTIFY, announce handling) via DKMS.

`xone` blacklists and replaces `xpad`.

### Known risks

| Risk | Impact | Notes |
|---|---|---|
| Upstream `medusalix/xone` is archived | Must pick a maintained fork | Verify fork activity before selecting |
| Kernel 7.1 is very new | DKMS build may fail against 7.1 headers | **Primary risk.** May need a patch |
| `xone` replaces `xpad` | Other Xbox pads move to `xone` | DS4 (`054C:09CC`, `hid_playstation`) unaffected |
| Kernel upgrade | Module must rebuild | See §6 — this is the tracked concern |

---

## 5. Acceptance criteria

A fix is complete only when **all** of these pass.

- **AC1 — Wire level.** `usbmon` capture shows `INPUT_REPORT` (GIP cmd `0x20`)
  count **> 0** from the controller.
- **AC2 — evdev level.** A 60 s capture on the controller's `event*` node
  while all controls are exercised yields events for: both sticks (`ABS_X/Y`,
  `ABS_RX/RY`), both triggers (`ABS_Z`, `ABS_RZ`), D-pad
  (`ABS_HAT0X/Y`), and all 11 buttons.
- **AC3 — Steam level.** Input is registered in Steam Big Picture controller
  test, and in at least one Proton game.
- **AC4 — Durability.** Survives a reboot into a **newly installed kernel**
  with no manual intervention. See §6.

---

## 6. Kernel-upgrade resilience (primary tracking concern)

A new kernel will not have the module until DKMS rebuilds it. Requirements:

- **R1** — `kernel-devel` must be installed for every kernel that gets
  installed, at the time it is installed. DKMS cannot build without matching
  headers.
- **R2** — DKMS autoinstall must be wired to kernel installation. Fedora's
  `dkms` package ships a `kernel-install` hook; confirm it fires rather than
  assuming it.
- **R3** — Post-upgrade verification must be a single deterministic command,
  not a guess. Candidate:
  ```
  dkms status && lsmod | grep -E 'xone|xpad'
  ```
- **R4** — A failed rebuild must be **loud**, not silent. A silent DKMS
  failure presents identically to the original bug (pad detected, no input),
  which will cost time to re-diagnose. Decide on a check at boot or a
  documented first-step-after-reboot.
- **R5** — Secure Boot is currently **disabled**. If it is ever enabled, DKMS
  modules require MOK enrollment and signing, or they will silently fail to
  load. Re-check this assumption after any firmware change.

### Open questions

- [ ] Which `xone` fork is maintained and builds against kernel 7.1?
- [ ] Does `xone` handle the interface-1 audio endpoints, or leave them unbound?
- [ ] Is a `xone`-specific udev rule needed, or is `uaccess` tagging automatic?
- [ ] Does the pad expose its extra Victrix features (profile switches,
      trigger stops) or only the base gamepad?
- [ ] Preferred R4 mechanism: boot-time check, dnf hook, or manual runbook step?

---

## 7. Rollback

`xpad` is in-tree and unmodified; the fix is purely additive.

1. `sudo dkms remove xone/<version> --all`
2. Remove the `xpad` blacklist file installed by `xone`
3. `sudo modprobe xpad`

This restores the current (broken-but-known) state. No in-tree files are
modified at any point.

---

## 8. Reproducible verification procedure

Reference method used during diagnosis. Re-run to validate any fix.

**Wire-level capture (AC1)** — requires root:

```bash
sudo modprobe usbmon
# capture bus 3 (adjust to the bus the pad is on)
sudo timeout 25 cat /sys/kernel/debug/usb/usbmon/3u > usbmon.txt
# force re-enumeration in another shell while capturing:
sudo sh -c 'echo 0 > /sys/bus/usb/devices/3-2.1/authorized'
sudo sh -c 'echo 1 > /sys/bus/usb/devices/3-2.1/authorized'
```

Decode GIP message types; `INPUT_REPORT` is command byte `0x20`:

```
0x01 ACK    0x02 ANNOUNCE  0x03 STATUS   0x04 IDENTIFY
0x05 POWER  0x06 AUTH      0x0a LED      0x20 INPUT_REPORT
```

**evdev capture (AC2):** read `struct input_event` (`struct llHHi`) from the
pad's `event*` node for 60 s while exercising every control; count distinct
`(type, code)` pairs.

**Confounder check:** before trusting a zero-event result, confirm no process
holds an exclusive grab — `ioctl(fd, EVIOCGRAB=0x40044590, 1)` must succeed.

**Extra `xpad` logging:**

```bash
sudo sh -c "echo 'module xpad +p' > /sys/kernel/debug/dynamic_debug/control"
# ... reproduce ...
sudo sh -c "echo 'module xpad -p' > /sys/kernel/debug/dynamic_debug/control"
```

---

## 9. Long-term resolution

The durable fix is an upstream `xpad` device-table entry plus correct generic
GIP ACK/IDENTIFY handling — removing the need for an out-of-tree module
entirely. Out of scope for now; recorded so the DKMS dependency is understood
as a workaround, not an endpoint.

---

## 10. Evidence log

Raw observations behind §3. Recorded so conclusions can be re-audited without
re-running the whole diagnosis.

### 10.1 evdev captures (2026-08-25, kernel 7.1.9-200)

| Capture | Duration | Result |
|---|---|---|
| 1 | 30 s | `TOTAL_EVENTS=0` |
| 2 | 60 s | `TOTAL_EVENTS=0  DISTINCT_CONTROLS=0` |

Confirmed by operator that all controls — buttons, sticks, **and D-pad** —
were exercised during both windows. `EVIOCGRAB` succeeded immediately before
capture 2, so no exclusive grab was starving the reader. Steam (pid 9461) held
`event1` open read-only throughout; this does not block other readers.

### 10.2 `xpad` canned init packets confirmed present in the running module

Extracted from `/lib/modules/7.1.9-200.fc44.x86_64/kernel/drivers/input/joystick/xpad.ko.xz`
and byte-searched. All present:

| Symbol | Bytes | Found |
|---|---|---|
| `xboxone_power_on` | `05 20 00 01 00` | yes |
| `xboxone_s_init` | `05 20 00 0f 06` | yes |
| `xboxone_pdp_led_on` | `0a 20 00 03 00 01 14` | yes |
| `xboxone_pdp_auth` | `06 20 00 02 01 00` | yes |
| `extra_input_packet` | `01 20 00 09 00 04 20 3a` | yes |

This confirms the packets seen on the wire originate from `xpad`'s hardcoded
table and are not a build/packaging anomaly — i.e. the driver is behaving as
written, and the limitation is in its design, not its installation.

### 10.3 Kernel log during forced re-enumeration

With `module xpad +p` dynamic debug enabled:

```
xpad 3-2.1:1.0: xpad_irq_in - urb shutting down with status: -108   (ESHUTDOWN)
usb 3-2.1: authorized to connect
xpad 3-2.1:1.0: xpad_irq_in - urb shutting down with status: -2     (ENOENT, x5)
```

The repeated `-2` completions are the IN urb being killed and resubmitted on
each retry of the failing init sequence — consistent with the §3 loop.

### 10.4 Device paths are not stable

`3-2.1` and `event1` are **as-observed values, not identifiers.** Both change
across replug and reboot. `verify.sh` resolves the device by `idVendor`/
`idProduct` and by `/dev/input/by-id/*Victrix*event-joystick` instead. Do not
hardcode the §2 paths in any tooling.

---

## 11. Host state left by the diagnostic session (2026-08-25)

| Change | State | Persists reboot? |
|---|---|---|
| `xpad` dynamic debug | re-disabled (`module xpad -p`) | no |
| `usbmon` module | **still loaded** (was in use at cleanup) | no |
| `xone` / DKMS | **not installed** — no change made | n/a |
| `xpad` | in-tree, untouched | n/a |

No persistent modification was made to the system. The pad remains broken in
exactly the state described in §3.

---

## 12. Changelog

Append an entry per working session. Keep newest last.

### 2026-08-25 — Diagnosis
- Root-caused to `xpad` GIP init failure; confirmed at USB wire level with
  `usbmon` (§3). Zero `INPUT_REPORT` emitted.
- Ruled out permissions, Flatpak sandbox, exclusive grab, Steam Input config,
  USB autosuspend, cable/power (§3).
- Recorded environment, Secure Boot state (disabled), DKMS state (empty).
- Wrote `verify.sh` covering AC2 + environment reporting.
- **No fix applied.** `xone` fork selection remains the blocking open question.

### 2026-08-25 — Repo setup
- Relicensed `GPL-3.0` -> **`GPL-2.0-only`** to match Linux (`GPL-2.0-only`)
  and `xone` (`GPL-2.0`). GPL-3.0 is one-way incompatible with the kernel and
  would have blocked the §9 upstream `xpad` patch and any `xone` fork carried
  here. Relicensing was free at this point — sole author, one prior commit.
- Added SPDX identifiers to `SPEC.md` and `verify.sh`; the kernel expects them
  on submitted patches.
- `LICENSE` replaced with canonical GPLv2 text (md5 `b234ee4d69f5fce4486a80fdaf4a4263`),
  taken from a local distro copy rather than fetched.
