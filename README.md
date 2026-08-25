<!-- SPDX-License-Identifier: GPL-2.0-only -->

# Victrix Gambit Prime on Linux

Getting the Turtle Beach Victrix Gambit Prime wired controller (`0e6f:0250`)
working for Proton gaming on Fedora, and keeping it working across kernel
upgrades.

**Status: solved.** The pad works. The in-tree `xpad` driver cannot drive it;
`xone` can.

If you own this controller and found this repo because it does nothing on
Linux, the [fix](#the-fix) is two commands. As of this writing there were no
other reports of this specific device working on Linux.

## The symptom

The controller enumerates perfectly and is completely dead.

`lsusb` sees it. `xpad` binds it. `/dev/input/js0` and an `event*` node appear
with a full capability bitmap advertising six axes, a D-pad and eleven buttons.
Steam detects it, applies a valid SDL mapping, and reserves an XInput slot.

It emits **zero input events**. Ever.

Everything above the driver looks healthy because all of it is built from USB
*descriptors*, which are valid. Only the data never arrives. See
[`CONTEXT.md`](CONTEXT.md) for the vocabulary this repo uses to keep those
states apart, because collapsing them into the word "detected" is what makes
this class of bug hard to read.

## Root cause

The pad is a **GIP** device (Xbox One/Series protocol), identified by USB
interface class `ff` / subclass `0x47` / protocol `0xd0`. It is not an Xbox
360-protocol pad.

`xpad` has no device-table entry for `0250`, so it matches the vendor-wide
`XPAD_XBOXONE_VENDOR(0x0e6f)` catch-all and names it `Generic X-Box pad`. Its
generic GIP init then never completes, because it sends neither `ACK` (`0x01`)
nor `IDENTIFY` (`0x04`). Unacknowledged, the pad re-announces every 500 ms
forever and never enters streaming state.

Captured with `usbmon`, the two drivers doing the same job:

| Packet (host to pad) | `xpad` | `xone` |
|---|---|---|
| **ACK** | **0** | **14** |
| **IDENTIFY** | **0** | **1** |
| AUTHENTICATE | 6, unanswered | 12, with 25 replies |
| ANNOUNCE from pad | 4, looping | **1**, acknowledged |
| **INPUT_REPORT** | **0** | streams at 208 Hz |

`xpad` produces a monologue. `xone` produces a conversation.

Note that `xpad` *does* contain the missing ACK+IDENTIFY packet, as
`xboxone_hori_ack_id`. It is hard-gated to two other PIDs. Adding `0e6f:0250`
to that table may be sufficient and is untested (issue #5).

## The fix

Install [`dlundqvist/xone`](https://github.com/dlundqvist/xone), the maintained
successor to `medusalix/xone`. It implements the GIP state machine properly.

```bash
sudo dnf install dkms kernel-devel-$(uname -r)
git clone https://github.com/dlundqvist/xone && cd xone
sudo ./install.sh
```

This blacklists `xpad`. With Secure Boot enabled you must enrol the DKMS MOK
key first, or the modules will silently fail to load.

Verified on Fedora 44, kernel `7.1.9-200.fc44.x86_64`, gcc 16, xone v0.5.8.

### What changes afterwards

Steam sees a **different controller**, so saved per-game bindings stop matching:

| | `xpad` | `xone` |
|---|---|---|
| Name | `Generic X-Box pad` | `Microsoft Xbox Controller` |
| SDL GUID | `030086656f0e00005002000000040000` | `0600b7926f0e00005002000000020000` |
| Buttons mapped | 11 | **12**, adds `misc1` |

Expect to redo per-game bindings once. This looks like a failed install and
is not. You gain a button `xpad` never exposed.

## Scripts

| Script | Purpose |
|---|---|
| [`verify.sh`](verify.sh) | Reports environment and captures input. **The only proof the pad works.** |
| [`probe-build.sh`](probe-build.sh) | Compiles an out-of-tree module against the running kernel. Never installs. |
| [`durability-test.sh`](durability-test.sh) | Re-enumerates N times and detects the announce loop. |
| [`recover.sh`](recover.sh) | Unwedges the pad on stock `xpad`. Obsolete once `xone` is installed. |

```bash
./verify.sh 20        # press every control for 20 seconds
```

### A trap worth knowing

**Wire silence does not prove success.** `xpad` also goes quiet when it gives
up on a wedged pad, so an absent retry loop is not evidence of a working link.
Only input reports prove streaming. This produced a false positive during
diagnosis and was originally baked into `durability-test.sh`. Always confirm
with `verify.sh` and real input.

## Kernel upgrades

DKMS must rebuild the module for each new kernel. The failure mode is nasty: a
**silent rebuild failure is indistinguishable from the original bug**, because
`xpad` reclaims the pad and it looks detected but dead.

After a kernel upgrade:

```bash
dkms status && ./verify.sh 20
```

See [`SPEC.md`](SPEC.md) §6 for the full requirements (R1-R5).

## Known issues

**S.T.A.L.K.E.R. 2 has delayed button input.** This is a game bug, not a
controller or driver fault. A Sony DS4 on `hid_playstation` — different vendor,
protocol, driver and code path — shows the same delay in the same title while
working correctly in Cyberpunk 2077 on the same Proton build. Present on both
Proton Experimental and 10.0-4. Every layer below the game is eliminated by
measurement. See issue #6.

Cyberpunk 2077 works correctly.

## Repo layout

```
README.md            this file
SPEC.md              full diagnosis, acceptance criteria, evidence log
CONTEXT.md           glossary: the bring-up states and failure modes
docs/adr/            architecture decision records
docs/agents/         agent-skill configuration
*.sh                 the scripts above
```

`SPEC.md` is the detailed record, including the wire captures, the durability
results, and the corrections made along the way.

## Licence

`GPL-2.0-only`, to stay compatible with Linux and `xone`. See
[ADR 0001](docs/adr/0001-gpl-2.0-only.md). Files under `docs/agents/` are
third-party MIT text and carry their own headers.
