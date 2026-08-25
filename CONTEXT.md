<!-- SPDX-License-Identifier: GPL-2.0-only -->

# Controller Bring-Up

The domain of getting a USB game controller from "plugged in" to usable in a
game on Linux, and keeping it there across kernel upgrades. This repo tracks one
instance: playing Proton games with the Victrix Gambit Prime (`0e6f:0250`) on
Fedora.

## Bring-up states

Ordered, and each separately observable. **None of the first four implies the
next.** Collapsing them into "detected" is what makes this class of bug hard to
diagnose.

**Enumerated**:
The device is on the USB bus and its descriptors have been read successfully.
_Avoid_: connected, recognised

**Bound**:
A kernel driver has claimed the device's interface.
_Avoid_: loaded, installed

**Advertised**:
An input node exists and publishes capability bitmaps describing the controls
the device claims to have.
_Avoid_: supported, has buttons

**Opened**:
An application holds the input node open and has resolved a mapping for it.
_Avoid_: detected by Steam, seen by Steam

**Streaming**:
The device is emitting input reports. The first state not derivable from
descriptors, and necessary but **not sufficient** for Playable.
_Avoid_: working, detected, functional

**Playable**:
Input reaches a Proton game correctly mapped, via Steam Input's translation
layer. The done-state for this repo — a controller can be Streaming and still
not Playable if the mapping or the per-game config is wrong.
_Avoid_: working, done, supported in Steam

**Descriptor-derived**:
Any observation originating in the device's USB descriptors rather than in data
the device has sent. Enumerated, Bound, Advertised and Opened are all
descriptor-derived — which is why all four can be green while nothing works.
_Avoid_: static info, metadata

## Failure modes

**Announce loop**:
A GIP device repeatedly re-announcing itself, never reaching Streaming, because
the host never completes the handshake the device is waiting for.
_Avoid_: handshake failure, init failure, not responding

**Silent rebuild failure**:
An out-of-tree module that fails to rebuild for a new kernel and is absent at
boot. Presents identically to an Announce loop, because the in-tree driver
reclaims the device and reaches Advertised without Streaming.
_Avoid_: DKMS broke, module missing

**Mapping drift**:
A Streaming device whose controls arrive mislabelled, or with a stale per-game
config applied. Changing the bound driver changes the device's name and SDL
GUID, so Steam treats it as a new controller and previously-saved configs stop
matching.
_Avoid_: wrong buttons, config broken

## Protocol and drivers

**GIP**:
The Xbox One / Series controller protocol, identified by USB interface subclass
`0x47` / protocol `0xd0`. Distinct from the older Xbox 360 controller protocol.
_Avoid_: Xbox protocol, XInput

**Input report**:
The GIP message carrying actual control state. Its presence is the definition of
Streaming and the primary acceptance signal.
_Avoid_: input event, packet, HID report
