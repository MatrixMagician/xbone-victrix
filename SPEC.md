<!-- SPDX-License-Identifier: GPL-2.0-only -->

# SPEC: Victrix Gambit Prime (0e6f:0250) controller support on Fedora

**Status:** Diagnosed — fix not yet applied
**Owner:** oliverh
**Created:** 2026-08-25
**Host:** neurodev

---

## 1. Problem statement

The Turtle Beach Victrix Gambit Prime wired controller (USB-C) reaches
`Opened` — Steam holds it open with a valid mapping — but never reaches
`Streaming`: it produces **zero input events**. No button, stick, trigger, or
D-pad input reaches any application. See `CONTEXT.md` for these state names.

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
- Steam Input misconfiguration — config sets are empty (normal default);
  `Opened` and mapped, confirmed in Steam's own log
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
| Upstream `medusalix/xone` is in maintenance mode | Must use the designated successor fork | **Not archived** (verified via GitHub API), but its README declares maintenance mode and points at `dlundqvist/xone`. Last commit 2025-12-21, last release v0.3 (2022) |
| ~~Kernel 7.1 is very new~~ | ~~DKMS build may fail~~ | **Retired 2026-08-25.** `dlundqvist/xone` master `f2aa9fe` builds clean against 7.1.9-200.fc44 with gcc 16 — 9 modules, 0 errors. Reproduce with `./probe-build.sh https://github.com/dlundqvist/xone` |
| `xone` replaces `xpad` | Other Xbox pads move to `xone` | DS4 (`054C:09CC`, `hid_playstation`) unaffected |
| Kernel upgrade | Module must rebuild | See §6 — this is the tracked concern |
| **Mapping drift** | Saved Steam configs stop matching | `xone` changes the device name and SDL GUID, so Steam sees a *new* controller. The existing `Generic X-Box pad` / GUID `030086656f0e00005002000000040000` / `configset_e6f-250-992ee0.vdf` will no longer apply. Expect to redo per-game bindings — this will look like a failed fix at exactly the wrong moment |

---

## 5. Acceptance criteria

The goal of this repo is **playing Proton games with this pad** — so AC3 is the
definition of done. AC1 and AC2 are leading indicators: they prove the driver
problem is solved, which is necessary but **not sufficient**. A pad can be
`Streaming` perfectly and still be unplayable through Steam Input. See
`CONTEXT.md`.

### Primary — definition of done

- **AC3 — Playable.** Input is correctly mapped and usable in-game in **both**:
  - **Cyberpunk 2077** (appid `1091500`)
  - **S.T.A.L.K.E.R. 2: Heart of Chornobyl** (appid `1643320`)

  Two titles rather than one because they exercise different paths: a saved
  per-game Steam Input config vs a fresh one. Also confirm the Steam Big Picture
  controller test registers every control.

- **AC4 — Durability.** AC3 still passes after a reboot into a **newly
  installed kernel**, with no manual intervention. See §6.

### Leading indicators — necessary, not sufficient

- **AC1 — Wire level.** `usbmon` capture shows `INPUT_REPORT` (GIP cmd `0x20`)
  count **> 0** from the controller.
- **AC2 — evdev level.** A 60 s capture on the controller's `event*` node
  while all controls are exercised yields events for: both sticks (`ABS_X/Y`,
  `ABS_RX/RY`), both triggers (`ABS_Z`, `ABS_RZ`), D-pad
  (`ABS_HAT0X/Y`), and all 11 buttons. This is what `verify.sh` checks —
  it **cannot** verify AC3.

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
  failure presents *identically* to the original bug: `xpad` reclaims the pad
  and it reaches `Advertised` but never `Streaming`. Indistinguishable without
  running `verify.sh`, so it will cost time to re-diagnose. Decide on a check at
  boot or a documented first-step-after-reboot.
- **R5** — Secure Boot is currently **disabled**. If it is ever enabled, DKMS
  modules require MOK enrollment and signing, or they will silently fail to
  load. Re-check this assumption after any firmware change.

### Open questions

- [x] **Which `xone` fork is maintained and builds against kernel 7.1?**
      `dlundqvist/xone`, the successor designated by `medusalix/xone`'s README.
      v0.5.8 (2026-03-17), active issue triage through Aug 2026. Master
      `f2aa9fe` builds clean against 7.1.9-200.fc44 with gcc 16 (9 modules,
      0 errors), verified locally via `./probe-build.sh`. Tracked in issue #1.
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

## 9. Upstream dependency

**Out of scope: this repo does not aim to fix `xpad` for everyone.** Its goal is
making this pad playable on this box.

That said, the underlying gap is an upstream one — `xpad` lacks a device-table
entry for `0250` and lacks correct generic GIP ACK/IDENTIFY handling. If a
future kernel fixes it, the `xone` dependency and its whole §6 rebuild burden
can be dropped. Worth re-checking on major kernel bumps:

```bash
# does this kernel's xpad know the device yet?
modinfo xpad | grep -i '0250'
```

Recorded so the DKMS dependency is understood as a workaround with a possible
expiry, not a permanent fixture.

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

### 2026-08-25 — Scope pinned to gaming
- Scope decided: this repo tracks making the pad **playable in Proton games**,
  not fixing `xpad` upstream. §9 reframed from "long-term resolution" to
  "upstream dependency".
- AC3 promoted to definition of done and given named titles — Cyberpunk 2077
  (`1091500`) and S.T.A.L.K.E.R. 2 (`1643320`). AC1/AC2 demoted to leading
  indicators; `verify.sh` covers AC2 only and cannot verify AC3.
- Added `CONTEXT.md` glossary. The five bring-up states (`Enumerated`, `Bound`,
  `Advertised`, `Opened`, `Streaming`) plus `Playable` replace the overloaded
  word "detected", which hid the bug: four states green, no data.
- Added **Mapping drift** risk — `xone` changes the device name and SDL GUID, so
  Steam sees a new controller and saved per-game configs stop matching.
- Added ADR 0001 (GPL-2.0-only).

### 2026-08-25 — Fork selected, alternatives tested, issues filed
- **Fork chosen: `dlundqvist/xone`.** Build verified locally, not inferred from
  a README. `probe-build.sh` added as the rerunnable proof.
- **Corrected:** `medusalix/xone` is **not archived** (GitHub API,
  `"archived": false`). It is in maintenance mode and points at the fork above.
  The earlier "archived" claim in §4 was wrong.
- **Kernel-7.1 risk retired.** It was the primary risk; a compiler settled it.
- **Alternative tested and rejected: SDL3 userspace GIP.** Steam's bundled
  SDL3 does contain the GIP driver (`SDL_hidapi_gip`), so a zero-install path
  looked plausible. Blacklisting `xpad` to free the interface produced no SDL
  claim in 25 s — only `hid_read failure` as Steam dropped the old node.
  Untested variant: Steam restarting while the interface is free, since SDL may
  only enumerate libusb at startup.
- **Alternative found, not yet tested: one-line `xpad` patch.** `xpad` already
  carries the missing ACK+IDENTIFY as `xboxone_hori_ack_id`, gated to
  `0e6f:0165` and `0f0d:0067`. Adding `0e6f:0250` may be sufficient. Issue #5.
- **§9 check run for the first time:** kernel 7.1.9's `xpad` still has no `0250`
  alias. Three `0e6f` entries, all vendor wildcards. Gap still open upstream.
- Issues #1-#5 filed with `ready-for-agent` / `ready-for-human` labels and
  native GitHub blocking edges.

---

## 13. Intermittent Streaming without a driver change (2026-08-25)

The pad reached `Streaming` on stock `xpad`, with nothing installed. This
section records what was measured, because it is easy to mistake for a fix.

### What was measured

| Observation | Value |
|---|---|
| Wire rate while working | 208 Hz (`bInterval 4` = 250 Hz ceiling) |
| URB errors | none |
| Retry loop while working | none — host sends nothing |
| Idle drift | 0 events in 10 s |
| Controls confirmed | all 6 analog axes, D-pad (`ABS_HAT0X/Y`), buttons |
| `xone` / DKMS | **not installed** |
| Bound driver | `xpad`, unchanged |

Input reports are **change-driven**, not continuous. A passive capture at rest
shows nothing even when the link is healthy.

### Cause

The GIP handshake completed. `xpad` did not change; the pad's state machine did.
Repeated failed init attempts wedge it, and no amount of retrying recovers it
because `xpad` keeps sending the same packets it never ACKs or IDENTIFYs.
Leaving the device completely unclaimed lets it reset.

The white LED is the hardware-side signal that init passed.

### Durability: it does not survive re-enumeration

`durability-test.sh` — **0/5 cycles** reached `Streaming`; each returned
`auth_retries=6`, the announce loop from §3. A reboot is a re-enumeration.

**Caveat, recorded deliberately.** A later single re-enumeration produced
`auth_retries=0`. So the wedge is **not** reliably reproducible on every
replug. Do not treat "breaks on every replug" as established.

### Recovery ritual, and why ordering is load-bearing

`recover.sh`. The sequence is:

1. blacklist `xpad`, `rmmod`, re-enumerate — pad sits unclaimed
2. hold ~25 s so its state machine resets
3. remove blacklist, `modprobe xpad`
4. **re-enumerate again** so `xpad` probes a *fresh arrival*

Step 4 is not optional. Loading `xpad` against an **already-present** device
fails; probing a **freshly arriving** device succeeds. Both were measured.

This is a workaround. It does not survive a replug and is not a substitute
for #1.

### Verification trap

`auth_retries=0` does **not** prove success. `xpad` also goes quiet when it
gives up on a wedged pad. This produced a false positive during diagnosis, and
`durability-test.sh` originally encoded the same error. Silence proves nothing.
**Only input reports prove `Streaming`** — always confirm with `./verify.sh`.

### Still unexplained

The Cyberpunk 2077 hang and S.T.A.L.K.E.R. 2 input lag. The wire link was clean
while both occurred, so they sit above the driver in the Steam Input and Proton
chain. The DS4 avoids them and takes a shorter natively-supported path. Not
diagnosed; needs a capture taken during an actual hang.

---

## 14. Resolution: xone installed (2026-08-25)

`dlundqvist/xone` v0.5.8 installed via DKMS. AC1 and AC2 pass. The workaround
in §13 is obsolete.

### Mechanism, confirmed at the wire

The §3 diagnosis said `xpad` never sends `ACK` (0x01) or `IDENTIFY` (0x04).
A usbmon capture of `xone` performing the same init proves the contrast:

| Packet (host -> pad) | `xpad` | `xone` |
|---|---|---|
| **ACK** | **0** | **14** |
| **IDENTIFY** | **0** | **1** |
| AUTHENTICATE | 6, unanswered | 12, with 25 replies |
| ANNOUNCE from pad | 4, looping | **1**, acknowledged |
| INPUT_REPORT | **0** | streams |

The pad announces once, is acknowledged, completes a bidirectional auth
exchange, and enters `Streaming`. `xpad` produced a monologue; `xone` produces
a conversation.

### Install state

| Item | Value |
|---|---|
| DKMS | `xone/0.5.8, 7.1.9-200.fc44.x86_64: installed` |
| Modules | `xone_gip`, `xone_wired`, `xone_gip_gamepad` (9 built, signed) |
| Driver on `:1.0` | `xone-wired` |
| Driver on `:1.1` | `xone-wired` (headset iface; `xpad` left this unbound) |
| Blacklist | `/etc/modprobe.d/xone-blacklist.conf` (`xpad`, `mt76x2u`) |
| DS4 `054C:09CC` | unaffected, still `hid_playstation` |

`mt76x2u` was checked before install. This host's MediaTek device `0e8d:0717`
is Bluetooth on `btusb`, and WiFi is `mt7925e`. The blacklist is inert here.
**Re-check if MediaTek USB WiFi is ever added.**

### Durability: the §13 failure is fixed

| Test | Workaround (§13) | `xone` |
|---|---|---|
| Re-enumeration cycles reaching bound state | **0/5** | **5/5** |
| Recovery ritual needed | yes | **no** |

AC2 confirmed by `./verify.sh` after 5 consecutive replugs. All 8 axes and the
D-pad were confirmed in a separate run on `xone`.

### Mapping drift: measured, not predicted

| | Before (`xpad`) | After (`xone`) |
|---|---|---|
| Name | `Generic X-Box pad` | `Microsoft Xbox Controller` |
| SDL GUID | `030086656f0e00005002000000040000` | `0600b7926f0e00005002000000020000` |
| Buttons mapped | 11 | 12, adds `misc1:b11` |

Steam has generated a fresh mapping. Saved bindings under
`configset_e6f-250-992ee0.vdf` will not carry over. `misc1` is a twelfth button
`xpad` never exposed.

### Still open

- **AC3 / AC4 unproven.** Playable in both titles is untested, and no reboot
  onto a new kernel has happened yet. §6 R1-R5 remain live.
- The §13 hang and input lag were never driver-level. Whether `xone` changes
  them is unknown. Issue #6.

### 2026-08-25 — Post-install game results
- **Cyberpunk 2077 works.** AC3 half met. The earlier hang happened under the
  §13 wedged-`xpad` state and has not recurred under `xone`.
- **S.T.A.L.K.E.R. 2 works with Steam Input disabled**, but buttons and
  shoulder buttons lag until another input occurs. Driver exonerated by
  measurement: LB/RB emit standalone evdev transitions with sticks untouched,
  66 transitions, 7.8 ms minimum gap. Fault is above the driver. Issue #6.
- **Correction.** An earlier note called S.T.A.L.K.E.R. 2 GameInput-only. Wrong.
  The shipping binary references both `GameInput.dll` and
  `XInput1_3/1_4/9_1_0.dll`; the XInput fallback is what works today.
- Host SDL3 3.4.14 sees the pad correctly: `is_gamepad=True`, full mapping,
  `SDL_GetGamepads` returns 1, identical with HIDAPI on and off.
