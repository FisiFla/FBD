# DDC equivalence audit — FBD vs. didriksg/Crisp v1.7.1

**Subject.** FBD's DDC/CI transport — the path from a UI action to bytes on the I2C
bus and back — compared component by component with the transport of
[didriksg/Crisp](https://github.com/didriksg/Crisp) at tag **v1.7.1**
(`242a8ce46fb86dd2b0a084619047cd3edfdfe31c`, MIT).

**Method.** Source-level comparison of every component on that path: the private
symbol used, the wire framing, the reply handling, the timing, the concurrency,
and the way a display is matched to a DDC channel. Crisp is the reference
because its transport has been exercised against real hardware; FBD's has not
(see the honesty rule below).

**Rules observed while writing this audit.** No code, strings or assets were
copied from Crisp. Behaviour was re-derived from the DDC/CI specification and
from the rationale Crisp documents for its own choices; every line of FBD's
implementation is its own. Crisp's file names and line numbers are quoted so a
reader can check a claim — quoting a location is not copying an implementation.

## The honesty rule

This document claims **code-verified equivalence**: FBD's transport is
equivalent to Crisp v1.7.1's transport *at the level of the source*. It does
**not** claim hardware verification.

FBD's DDC path has never been exercised against a real DDC monitor in this
repository. The machine this audit was written on has no external display
attached. Issue [#7](https://github.com/FisiFla/FBD/issues/7) tracks the
empirical leg, and `scripts/ddc-smoke.sh` (issue #26) is the harness for it.

Two phrases are therefore never used interchangeably in this repository:

- **"resolves"** — the symbol exists in the binary. It says nothing about
  whether calling it works.
- **"was called"** — the code path ran. Only a checksum-valid DDC reply proves
  that a DDC path works at all.

## Summary

| # | Component | FBD | Crisp v1.7.1 | Verdict |
|---|---|---|---|---|
| 1 | Private symbol | `IOAVServiceCreateWithService` on the `DCPAVServiceProxy`, then `IOAVServiceReadI2C` / `IOAVServiceWriteI2C` on I2C address `0x37`, data address `0x51` | the same | **aligned** |
| 2 | Write framing | `[0x84, 0x03, code, hi, lo]` + checksum, seed `0x6E ^ 0x51` | the same | **aligned** |
| 3 | Read request framing | `[0x82, 0x01, code]` + checksum, seed `0x6E ^ 0x51` | the same | **aligned** |
| 4 | Reply validation | signature `0x6E`, opcode `0x02`, result `0x00`, the VCP echo, the reply checksum, and no zero maximum (except for a feature without a scale) | the same set of checks | **aligned** (divergent before `88d3329`) |
| 5 | Reply checksum seed | `0x50` over bytes 0…9 of the frame, `0x6E` included | the same | **aligned** |
| 6 | Read cache | 5 s TTL per (display, VCP code), dropped by a write | 5 s TTL per (display, VCP code), dropped by a write | **aligned** (divergent before `88d3329`) |
| 7 | Read quarantine | 6 consecutive failures → 600 s window; one attempt over 3 s → immediate quarantine; writes unaffected | the same | **aligned** (divergent before `88d3329`) |
| 8 | Capabilities probe | 32-byte fragments, ≤ 64 fragments, `vcp(…)` must be closed; a fragment over 3 s quarantines the display | the same | **aligned** (the deaf-fragment rule came with `88d3329`) |
| 9 | Read pacing | 100 ms between read operations, one slot per operation | no explicit pacing; the 5 s cache absorbs repeats | **divergent — equivalence holds because** (see §5) |
| 10 | Write delivery | coalesced latest-wins, one delivery per 1 s slot, no retry | 3 attempts 50 ms apart, no coalescing | **divergent — equivalence holds because** (see §6) |
| 11 | Bus contention | one serial queue per display + a traffic gate + a topology hold around enable/disable and mode switching | one serial queue per display + a hold around enable/disable | **aligned in behaviour** (divergent before `88d3329`) |
| 12 | Display ↔ channel matching | registry-order pairing: the first external `DCPAVServiceProxy` that follows a matching framebuffer | identity matcher (location, then serial, then model) with a traversal-order fallback and an ambiguity flag | **divergent — open** (see §7) |
| 13 | Maximum-value fallback | the maximum cached from the last valid read, else the MCCS default `100` | per-display cached caps | **divergent — equivalence holds because** (see §8) |

Alignment commit for rows 4, 6, 7, 8 and 11: `88d3329` — *"Issue #25: port DDC
hardening (validated replies, read TTL cache, quarantine, topology hold)"*.

---

## 1. The private symbol — aligned

Both implementations reach the display's DDC controller through the same three
symbols, declared once in FBD's shim
(`Sources/CPrivateAPI/include/fbd_private_api.h`):

| Step | Symbol | FBD | Crisp v1.7.1 |
|---|---|---|---|
| Find the display's service | `IOAVServiceCreateWithService` on the `DCPAVServiceProxy` | `Sources/FBDCore/PrivateAPI/IOAVServiceAPI.swift:21` (`findAVService`) → `findDPService` → `pairedExternalProxy` | `Crisp/Services/DDCService.swift` (`findAVService`) |
| Talk to the bus | `IOAVServiceReadI2C` / `IOAVServiceWriteI2C`, I2C address `0x37`, data address `0x51` | `IOAVServiceAPI.swift:189` / `:205` | `arm64Read` / `writeSynchronous` in `Crisp/Services/DDCService.swift` |

FBD's ledger entry for these symbols is in `docs/PRIVATE_APIS.md`
(`IOAVServiceCreateWithService`, `IOAVServiceReadI2C / WriteI2C`).

**Same symbol, same addresses, same frame.** The two implementations differ
only in how they find the service — see §7.

## 2–3. Request framing — aligned

| Direction | Frame | FBD | Crisp v1.7.1 |
|---|---|---|---|
| Write | `[0x84, 0x03, code, valueHi, valueLo, checksum]` | `DDCProtocol.swift:66` (`writeVCPPacket`) | `writeSynchronous` |
| Read | `[0x82, 0x01, code, checksum]` | `DDCProtocol.swift:77` (`readVCPRequest`) | `arm64Read` |

The checksum seed is `0x6E ^ 0x51` in both, XORed over the payload — FBD's
`DDC.checksum(_:includeSource:)` (`DDCProtocol.swift:58`) and Crisp's
inline `0x6E ^ 0x51` seed. A frame written by one is accepted by the other.

## 4–5. Reply validation — aligned since `88d3329`

**Before.** FBD parsed a reply as "at least 10 bytes, opcode `0x02`, result
`0x00`" and took the maximum and the current value from bytes 6…9 without
looking at anything else. Its own comment said so: the checksum is not checked
because m1ddc does not check it either.

That is the wrong reference point. A display can acknowledge the I2C read and
still answer with stale EDID bytes or a NULL frame. Those bytes pass a
header-only check, and a maximum of `0xFF` read out of them becomes the scale
every later brightness write is computed against — one bad reply and the
slider is dead for the rest of the session.

**Now.** `DDC.validateVCPReply(_:expecting:)` (`DDCProtocol.swift:133`) rejects
a reply unless it

- is at least 11 bytes,
- starts with the DDC/CI signature `0x6E`,
- carries the "Get VCP Feature Reply" opcode `0x02`,
- reports no error (`0x00`),
- echoes the VCP code that was asked for,
- passes its checksum — `0x50` XORed over bytes 0…9, with the `0x6E` header
  byte included, compared against byte 10 (`DDCProtocol.swift:97`), and
- carries a non-zero maximum, unless the feature is the input source, which
  has no scale and is reported as maximum `0` by some monitors.

The rejection reason is a value (`DDC.VCPReplyRejection`), not a boolean, so a
failure can be logged and asserted on. `DDC.parseVCPReply` now returns `nil`
for anything `validateVCPReply` rejects.

**The checksum seeds are not interchangeable.** A *request* checksum is seeded
with `0x6E ^ 0x51` (`0x3F`); a *reply* checksum is seeded with `0x50`. For the
canonical brightness reply `[0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64,
0x00, 0x32]` the two formulas give `0xF2` and `0x9D` respectively. FBD keeps
them apart: `DDC.checksum` for requests, `DDC.replyChecksum` for replies. The
value `0xF2` is pinned by a test.

**Equivalence with Crisp.** Crisp's `arm64Read` performs the same checks in
the same order — signature, opcode, result, echo, then the checksum, then the
zero maximum, with the same exception for the input source. The two
implementations agree on what a valid reply is.

**Where FBD is stricter.** FBD additionally requires the reply to be at least
11 bytes, because byte 10 is the checksum; Crisp's length check is `>= 10` and
its checksum read of `replyBuf[10]` is safe only because it allocates 12 bytes.
FBD reads a `Data` of exactly the requested length, so the check is required.

## 6–7. Read cache, quarantine and pacing — aligned since `88d3329`

### The 5-second read cache — aligned

Both implementations keep the last read value per (display, VCP code) for five
seconds and drop it as soon as a write to that code lands.

- FBD: `DDCReadCacheEntry` (`Sources/FBDCore/Controllers/DDCReadState.swift`),
  the cache in `DDCController.readCache`, TTL from `Settings.ddcReadCacheSeconds`
  (default 5).
- Crisp: `VCPCacheEntry` in `Crisp/Services/DDCService.swift` (line 57), with
  the same five-second expiry and the same invalidation on write.

One deliberate difference: FBD drops the cached entry when the write is
*accepted* for delivery, Crisp when the write *reaches* the display. FBD's
write is asynchronous and coalesced, so a write that is accepted and then
replaced by a newer value would leave Crisp's cache stale for up to a second.
Dropping early is the conservative direction: the next read asks the display
instead of the cache.

### The quarantine — aligned

A display whose DDC controller has stopped answering makes every read cost the
full I2C timeout. Both implementations give up on such a display for a while
rather than paying that cost on every request:

| Rule | FBD | Crisp v1.7.1 |
|---|---|---|
| Threshold | 6 consecutive failed attempts | 6 (`readQuarantineThreshold`) |
| Window | 600 s | 600 s (`readQuarantineInterval`) |
| Deaf channel | one attempt longer than 3 s quarantines at once | the same (`deafAttemptMs`) |
| During the window | reads fail fast, no bus traffic | the same |
| Writes | unaffected | the same |
| After the window | the streak is cleared; one fresh probe is allowed | the same |

FBD's implementation is `DDCReadHealth` (`Sources/FBDCore/Controllers/DDCReadState.swift`).
It is a pure state machine driven by an injected clock, so the whole matrix is
unit-tested without a display and without waiting — which is the point: a
quarantine that is only testable on hardware is a quarantine that never gets
tested.

A malformed reply counts as a failed attempt in both implementations. That is
the rule that makes the two halves of this issue work together: a display that
answers with garbage fails validation, the failure accumulates, and the display
is eventually quarantined instead of being asked again every second.

### The pacing — divergent, equivalence holds

FBD paces reads: 100 ms between read operations on the same display
(`Settings.ddcReadCooldownMilliseconds`). Crisp has no explicit read pacing;
its protection against read-hammering is the five-second cache plus the
quarantine.

**Why the divergence is fine.** The two mechanisms cover different failures.
Crisp's cache stops *repeated* reads of the same feature; the quarantine stops
reads of a *broken* display. Neither stops a caller that reads many different
features in a row — FBD's panel pass reads four features, and a display that
is slow to answer would spend four timeouts in a row. FBD's pacing bounds
that; Crisp's does not, because Crisp's read path is fully asynchronous and
never blocks a caller.

**Where FBD's pacing is deliberately coarse.** One pacing slot is taken per
*read operation*, not per feature: the panel's four-feature pass takes one slot
and then reads the other three back to back. Four slots would quadruple the
wait for no benefit — the four reads belong to one operation.

## 6. Write delivery — divergent, equivalence holds

| | FBD | Crisp v1.7.1 |
|---|---|---|
| Attempts | one delivery per scheduled slot | 3 attempts, 50 ms apart |
| Coalescing | latest-wins per (display, code) | none |
| Spacing | 1 s per display (`Settings.ddcCooldownMilliseconds`) | 50 ms between attempts |
| Delivery | asynchronous | asynchronous |
| Retry on failure | none | yes |

**Why the divergence is deliberate.** FBD's write path is a *slider*, not a
command: the user drags a value, and the display only has to end up at the
last value the user asked for. Coalescing a drag into one write per second is
the behaviour a slider wants, and the 1 s spacing keeps FBD's write traffic
well below the level that makes a monitor flicker its OSD. Retrying a write
that already went out would push a value the user has already moved past.

Crisp's write path is closer to a command: three attempts 50 ms apart, because
its callers are automations that need to know whether a value was applied.

**The honest cost of the divergence.** A failed write in FBD is lost, and
FBD's write is not read back, so neither implementation can *prove* a write
landed. Both say the same thing about it: an acknowledged write is not proof
that DDC works on that display. Only a checksum-valid read proves anything.
FBD's read path now validates, so that read is worth something.

**Issue #25 scoped the write cadence out explicitly**, so this divergence is
recorded rather than closed. It is the first thing to revisit if FBD ever
needs a write it can confirm.

## 8. Bus contention and the topology hold — aligned in behaviour

### One serial queue per display — aligned

Both implementations serialize all I2C traffic for one display on one queue
(FBD: `DDCQueuePool.queue(for:)`, keyed by `Display.identityKey`; Crisp:
`DDCOperationQueuePool`). A display that stops answering therefore cannot
stall the other displays.

### The topology hold — aligned in behaviour, different mechanism

WindowServer's display enable waits behind an in-flight I2C transaction, and
freezes the whole Mac while it waits. Both implementations therefore take the
bus to themselves before a topology change.

Crisp parks every per-display queue behind a semaphore with a 15 s safety cap
(`DDCOperationQueuePool.hold(timeout:)`) and awaits the queues going idle.

FBD uses a **traffic gate** instead (`Sources/FBDCore/Controllers/DDCQueuePool.swift`):
every I2C transaction is wrapped in `beginTransaction()` / `endTransaction()`,
and `hold()` waits for the transactions already in flight to drain before the
change is issued.

**Why a gate rather than parked queues.** A parked queue makes a caller *wait*.
FBD's callers include the main actor, and the main actor is usually the thread
that asked for the topology change: a DDC read that blocks there would wait for
the change that is waiting for it. FBD's gate therefore **fails fast** instead
of blocking:

- a read that arrives during a topology change returns `nil` and logs,
- a write that arrives during one is dropped and logged.

A caller that is refused knows it was refused and can try again later — the
refusal is reported (`DDCController.isTrafficPaused`), not silently turned
into a wrong answer. The capabilities probe is the one place that could have
blocked for a long time (up to 64 fragments); it now takes **one bus
transaction per fragment**, so a topology change can interleave between
fragments instead of waiting for the whole probe.

Where the hold is taken: `DisconnectController.setEnabled`
(`DisconnectController.swift:50`) and `ResolutionController.applyMode`
(`ResolutionController.swift:61`). Both release it before
`SkyLightAPI.detectDisplays()` runs, so the re-enumeration is not part of the
paused window.

**One difference in scope.** Crisp takes the hold around enable and disable;
FBD also takes it around a mode switch, because a mode switch reconfigures the
display the same way. FBD does not take it around `LayoutProtectionController`'s
arrangement transaction: that one moves display origins, it does not
reconfigure a display's mode.

## 9. Display ↔ channel matching — divergent, open

This is the largest remaining divergence and it is **not** closed by this audit.

FBD matches a display to its DDC channel by walking the `kIOServicePlane`
registry in order (`IOAVServiceAPI.pairedExternalProxy`,
`IOAVServiceAPI.swift:91`): it collects the framebuffer nodes and the
`DCPAVServiceProxy` nodes, then takes the **first** proxy marked
`Location == "External"` that comes **after** a framebuffer matching the
display's vendor/model/serial. When no framebuffer matches, it falls back to
the display's own service and then to its first `DCPAVServiceProxy` or
`IOAVService` child.

Crisp matches by **identity first**: the channel's stable location, then a
non-zero serial plus vendor plus product, then vendor plus product. Only
whatever identity matching could not place falls back to traversal order — and
when that fallback had to guess among more than one indistinguishable leftover,
Crisp marks the mapping **ambiguous** and tells the user about it.

**Why FBD's version is weaker.** Traversal order is not an identity. Two
external displays, or one display that re-enumerates after a hot-plug, can
leave FBD pairing the wrong channel with the wrong display. The symptom is a
brightness slider that drives the other monitor.

**Why it is still the right trade for now.** FBD's pairing falls back to
identity too — `framebufferMatches` compares vendor, model and serial from the
registry properties, and the EDID UUID prefix — but it applies it only to
*framebuffers*, not to channels, and it then takes the first proxy in
traversal order. It is a heuristic that happens to work on the common
single-external-display case.

**What closing it would take.** The same shape as the rest of this audit: the
matcher becomes a pure function over (display identity, candidate channel
identity) with its own tests, and the *ambiguous* case becomes a state the UI
reports rather than a guess it makes silently. That is a piece of work in its
own right, and it belongs to the display-matching layer rather than to the
transport — which is why it is left open here rather than claimed as aligned.

## 10. Maximum-value fallback — divergent, equivalence holds

Both implementations scale a continuous feature against the maximum the display
reported. They differ in what they do when no maximum is known.

FBD caches the maximum from the last valid read (`DDCController.lastMaxValue`)
and falls back to the MCCS standard `0…100` range (`DDCController.maxValue(for:display:)`).
Crisp keeps per-display cached caps.

**Equivalence holds because the fallback only runs before the first valid
read.** After the first valid reply the two behave identically, because a
valid reply always carries a non-zero maximum — that is one of the checks in
§4, and the reason a maximum of `0` is rejected rather than cached. The
difference is therefore a difference in the first second of a display's life,
not a difference in behaviour afterwards.

**The fallback is the reason reply validation matters so much.** A maximum
read out of a garbage reply would be cached and used as the scale for every
later write. Rejecting the reply means the scale stays at the MCCS default
until a real one arrives.

## 11. Capabilities probe — aligned

Both implementations fetch the capabilities string in 32-byte fragments
(request `0x83, 0xF3, offsetHi, offsetLo` + checksum), concatenate them, and
accept the result only when the string contains a closed `vcp(…)` group. Both
cap the number of fragments so a misbehaving display cannot loop forever.

FBD additionally treats a fragment that takes longer than three seconds as a
deaf channel and quarantines the display's reads immediately, rather than
waiting for the full six-failure streak — the same rule the VCP read path
uses, applied to the probe.

## What this audit does not claim

- **Not hardware verification.** FBD's DDC path has not been run against a
  real DDC monitor here. Issue #7 is the empirical leg; `scripts/ddc-smoke.sh`
  (issue #26) is its harness. Until that runs, the strongest true statement is
  the one this document makes: *code-verified equivalent to Crisp v1.7.1's
  hardware-proven transport*.
- **Not a behaviour match for the matching layer.** §9 is open.
- **Not a write-path match.** §6 is a documented, deliberate divergence.
- **Not a claim that Crisp is correct.** Crisp is the reference because it has
  been exercised against hardware, not because it is right. Where the DDC/CI
  specification disagrees with either implementation, the specification wins.

## Residual risk on real hardware

The parts of this audit that a code review cannot settle:

| Risk | Why the code cannot answer it | How it would be caught |
|---|---|---|
| A monitor that answers with a valid-looking frame whose checksum happens to match | the checksum is a one-byte check; it is strong against stale bytes and weak against a coincidence | the smoke script's write round-trip (issue #26) |
| A monitor whose maximum is `0` for a feature that *does* have a scale | the reply is rejected and the feature falls back to the MCCS default | the smoke script's read-back of every feature |
| A display whose channel is paired with the wrong display | §9 — FBD pairs by traversal order | the smoke script enumerating displays *through the app's matching layer*, so a wrong pairing shows up as a wrong name |
| A channel that answers slowly rather than not at all | the quarantine is driven by failures, not by slowness, unless the attempt crosses the 3 s deaf threshold | the smoke script's per-check timing |

## Reproducing this audit

Crisp at the audited revision:

```
git clone https://github.com/didriksg/Crisp
cd Crisp && git checkout v1.7.1     # 242a8ce46fb86dd2b0a084619047cd3edfdfe31c
```

The comparison is then a read of four Crisp files against four FBD files:

| Concern | Crisp | FBD |
|---|---|---|
| Transport | `Crisp/Services/DDCService.swift` | `Sources/FBDCore/PrivateAPI/IOAVServiceAPI.swift` |
| Wire format | `Crisp/Services/DDCService.swift` | `Sources/FBDCore/Controllers/DDCProtocol.swift` |
| Concurrency | `Crisp/Models/DDCOperationQueuePool.swift` | `Sources/FBDCore/Controllers/DDCQueuePool.swift` |
| Match | `Crisp/Models/DDCServiceMatcher.swift` | `Sources/FBDCore/PrivateAPI/IOAVServiceAPI.swift` |

FBD's own tests for the aligned parts are
`Tests/FBDCoreTests/DDCProtocolTests.swift`,
`Tests/FBDCoreTests/DDCControllerTests.swift`,
`Tests/FBDCoreTests/DDCQueuePoolTests.swift` and
`Tests/FBDCoreTests/DDCReadStateTests.swift` — they need no display and no
macOS version-specific behaviour, so they run in CI.
