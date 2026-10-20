# FBD — Private API registry

Every private API used by FBD, its verification source, and the tier that consumes it.
Signatures were verified against the macOS 27 dyld export trie (`dyld_info -exports`),
and FOSS implementations (lunar, displayplacer).

## Declared in `Sources/CPrivateAPI/include/fbd_private_api.h`

| API | Source | Used by | Tier |
|---|---|---|---|
| `CGSGetDisplayList` | displayplacer | CGSAPI | 1 |
| `CGSGetCurrentDisplayMode` | displayplacer | CGSAPI / ResolutionController | 1 |
| `CGSGetNumberOfDisplayModes` | displayplacer | CGSAPI | 1 |
| `CGSGetDisplayModeDescriptionOfLength` (struct `CGSDisplayModeDescription`, 212 B) | displayplacer `CDStructures.h` | CGSAPI | 1 |
| `CGSConfigureDisplayMode` | displayplacer | CGSAPI / ResolutionController | 1 |
| `CGSConfigureDisplayEnabled` | displayplacer | (declared; used in Tier 3 soft-disconnect) | 3 |
| `DisplayServicesGetBrightness / SetBrightness` | lunar Bridge.h, dyld exports | DisplayServicesAPI / AppleController | 1 |
| `DisplayServicesGetLinearBrightness / SetLinearBrightness` | lunar Bridge.h | AppleController | 1 |
| `DisplayServicesCanChangeBrightness` | lunar Bridge.h | AppleController | 1 |
| `DisplayServicesHasAmbientLightCompensation` | lunar Bridge.h | AppleController | 1 |
| `DisplayServicesAmbientLightCompensationEnabled / EnableAmbientLightCompensation` | lunar Bridge.h | AppleController | 1 |
| `DisplayServicesResetAmbientLight` | lunar Bridge.h | (declared; auto-brightness reset) | 2 |
| `DisplayServicesRegisterForBrightnessChangeNotifications` (+unregister) | lunar Bridge.h | (declared; brightness sync owns a global registry) | 2 |
| `IOAVServiceCreateWithService` | IOKit dyld exports | IOAVServiceAPI / ExternalController (DDC audit: `docs/ddc-equivalence.md`) | 1 |
| `IOAVServiceReadI2C / WriteI2C` | lunar arm64 path | IOAVServiceAPI / DDCController (DDC audit: `docs/ddc-equivalence.md`) | 1 |
| `IOAVServiceCopyEDID` | IOKit dyld exports | IOAVServiceAPI (Tier 4 EDID) | 4 |
| `SLSMainConnectionID` | yabai/skhd headers | SkyLightAPI | 1 |
| `SLSDetectDisplays` | IOKit dyld exports | SkyLightAPI / ResolutionController | 1 |

## Tier 2 declared (verified by live probe on macOS 27)

| API | Status on macOS 27 | Used by |
|---|---|---|
| `SLSDisplayCopyPresetData(display, index)` | ✅ reads work; 4 factory presets + blank slots 11–15 on built-in XDR | SkyLightAPI / XDRNativeController |
| `SLSDisplaySetPresetData(display, index, dict)` | ⚠️ **write-protected** — silently no-ops on valid AND blank slots (readback unchanged); `makeValidWithSettings:` (MonitorPanel) also restricted | XDRNativeController (self-tests, falls back to software upscaling) |
| `SLSDisplaySetActivePresetIndex(display, index)` | ✅ works (preset switch verified live) | XDRNativeController / preset picker |
| `SLSDisplayGetActivePresetIndex` | ❌ always -1 on macOS 27 — use `SLSDisplayCopyActivePreset` + uniqueID match instead | SkyLightAPI.activePresetIndex |
| `SLSDisplaySetActivePresetIndex` / `SLSDisplayCopyPresetData` | ✅ preset SWITCHING works on macOS 27 (live-verified 2026-08-02: `fbdcli preset <id> <index>` activates factory presets); only `SLSDisplaySetPresetData` (preset REWRITE) is write-protected | XDRNativeController, `fbdcli preset` |
| `SLSDisplayCopyActivePreset(display)` | ✅ returns active preset dict | SkyLightAPI |
| `SLSGetAppearanceThemeLegacy()` / `SLSSetAppearanceThemeLegacy(bool)` / `SLSSetAppearanceThemeNotifying(bool, bool)` | ✅ **live-verified 2026-10-14**: all three resolve in `SkyLight.framework`, and `fbdcli dark-mode on` / `off` both flip the system appearance (read back through the getter). Symbol names taken from Crisp's `CoreBrightnessService.swift`, which resolves the same three; the Notifying variant is preferred so the switch crossfades like Control Center's. Reached through `Sources/CPrivateAPI/fbd_appearance.c` — never declared in Swift | DarkModeController / `fbdcli dark-mode` |
| `SLSDisplayIsPresetValid / IsPresetWritable` | ✅ 2-arg confirmed (11–15 blank & writable) | SkyLightAPI |
| `SLSDisplayGetFactoryDefaultPresetIndex` | ✅ returns 0 | SkyLightAPI |
| `SLSDisplaySupportsHDRMode / IsHDRModeEnabled / SetHDRModeEnabled` | reports 0 for built-in XDR (external HDR displays expected true) | XDRNativeController |
| Preset data keys (`PresetHostMaxPotentialEDRHeadroom`, `PresetMaxHDRLuminance`, `PresetMaxSDRLuminance`, `PresetHostMaxSliderBrightness`, `PresetHostMinSliderBrightness`, `PresetName`, `PresetValid`, …) | ✅ read live from the built-in XDR (47–48 keys per preset) | SkyLightAPI / XDRPreset |
| `IOMobileFramebufferOpen` (type 0) | ❌ kIOReturnNotPrivileged — entitlement-gated; no Close export | IOMobileFramebufferAPI (probe-only, degrades) |
| `IOMobileFramebufferGetGammaTable / SetGammaTable / GetColorRemapMode / SetColorRemapMode` | exports present (GammaTable = 771×uint32) but unreachable without open | IOMobileFramebufferAPI |
| `DisplayServicesRegisterForBrightnessChangeNotifications` | ✅ pattern from lunar: observer token = display ID, value in userInfo["value"] | BrightnessChangeObserver |

## Tier 5 (verified)

| API | Status | Used by |
|---|---|---|
| `CBBlueLightClient` (CoreBrightness, ObjC runtime + C shims): `setStrength:commit:`, `getStrength:`, `supportsBlueLightReduction` | ✅ live-verified (strength round-trip 0–100 %) | NightShiftController |
| `CBTrueToneClient`: `available`, `enabled`, `setEnabled:` | ✅ live-verified 2026-10-20 on macOS 27.0.1 (built-in XDR panel): `available` = true, `enabled` reads back, `setEnabled:` round-trips (off → on, read back after each write). The "unavailable on macOS 26.3+" note came from Lunar's `CBTrueToneClient.h` and does not hold on macOS 27 | TrueToneController |
| Sparkle 2.9.5 (public, SPM) | ✅ linked; SUFeedURL configured (repo appcast), updater active when signed | UpdaterController |
| `CoreDisplay_DisplayCreateInfoDictionary` | ✅ live-verified (rich display info; no IODisplayEDID for built-in panel on macOS 27) | EDIDController fallback |

## Not yet declared (Tier 3+)

| API | Purpose | Tier |
|---|---|---|
| `SLSGetDisplayModeMinRefreshRate`, `SLSIsDisplayModeProMotion / VRR` | VRR/ProMotion metadata | 2→3 |
| `IOAVServiceSetVirtualEDIDMode` | EDID override (Apple Silicon) | 4 |
| `CGVirtualDisplay*` classes (`VirtualDisplay.framework`, dlopen — absent on macOS 26+) | virtual displays on macOS 13–15 only (not runtime-testable here) | 3 |
| `ColorSyncDeviceSetCustomProfiles` | color profiles / HDR color mode | 4 |
| `CBBlueLightClient`, `CBTrueToneClient` (CoreBrightness, ObjC runtime lookup) | Night Shift / True Tone | 5 |

| `SLSSetDisplayRotation(cid, displayID, rotation)` + `SLDisplayRotation` | ⚠️ **declared + wired (UI + `fbdcli rotate`), returns status 1001 for the built-in on macOS 27** — graceful failure; external-display check pending | SkyLightAPI / DisplayController / rotation submenu |

## DisplayPort link / DPCD / DSC — located 2026-10-14

Finding these symbols was blocked on *identifying* them. They are **all exported by the public
`IOKit.framework`**, so they are reached exactly like the `IOAVService*` set already declared
above — the same linkage, no `dlopen`, no ObjC runtime.

Names were read from the SDK stub (`$(xcrun --show-sdk-path)/System/Library/Frameworks/IOKit.framework/IOKit.tbd`
— `.tbd` files are plain-text symbol lists), then each was confirmed against the **running** OS with
`dlsym`, because an SDK stub only proves the SDK knew the name. Probe: `dlopen` IOKit + `dlsym` per
name on macOS 27.0.1 → **49 of 55 resolved**. Also present in the MacOSX26.5 and MacOSX27.0 stubs,
so this is not a one-release API.

**Read-only getters — the subset row #24 should use.** None of these write to the sink or put
anything on the AUX channel:

| Symbol | Serves |
|---|---|
| `IODPDeviceGetRevisionMajor` / `GetRevisionMinor` | decoded DPCD revision |
| `IODPLinkBandwidth`, `IODPVideoBandwidth`, `IODPLinkRateScalar` | link bandwidth |
| `IODPLinkRateEnum`, `IODPLinkRateIsStandard`, `IODPLinkRateIsUHBR` | link rate, incl. UHBR |
| `IODPDeviceGetMaxLaneCount` / `GetMaxLinkRate`, `IODPControllerGetMin/MaxLaneCount` | capability limits |
| `IODPDeviceGetLinkTrainingData`, `IODPDeviceGetSymbolErrorCount`, `IODPServiceGetSymbolErrorCount` | link health |
| `IODPDeviceGetSupportsDownspread`, `GetSupportsEnhancedMode` | sink capability flags |
| `IODPDeviceReadDPCD` | raw DPCD reads (the AUX path row #24 names) |
| `IOAVServiceGetLinkData` / `GetLinkDataWithSource`, `IOAVVideoInterfaceGetLinkData` | link data off the AVService |
| `IOAVVideoInterfaceCopyDisplayAttributes`, `IOAVServiceCopyProperties` / `CopyProperty` | already-parsed property dictionaries |
| `IOAVDSCCapabilitiesGetMaxSlicesPerLine`, `IOAVDSCCapabilitiesGetPeakPixelRateForMode`, `IOAVDSCModeForPixelEncoding`, `IOAVVideoColorMinimumBitsPerPixelDSC` (+ `kIOAVDSCCapabilitiesNone` / `kIOAVDSCHintsNone` / `kIOAVDSCParametersNone`) | DSC capability + PPS inputs |

`IOAVServiceGetDevice` walks AVService → Device; `IODPDeviceGetAVDevice` / `GetController` walk back.
Entry points are `IODPDeviceCreateWithService` / `IODPServiceCreateWithService` /
`IODPPortCreateWithService`, taking the same `IOService` the DDC path already finds.
`IOAVCopyFirstMatchingIOAVObjectOfType` and `IODPDeviceGetService` do **not** exist (probed), so
discovery must stay on service matching.

**`IODPDeviceReadDPCD` is used as of 2026-10-14**, through `Sources/CPrivateAPI/fbd_iodp.c` and
`IODPAPI` (`fbdcli dpcd <display>`, row 24). The shim declares **only** the read; everything in the
"deliberately not used" list below stays unused by policy. One caveat from the first live attempt: the
read declines at *service* discovery on the built-in panel, because `IOAVServiceAPI`'s registry walk is
tuned for external displays, so a read proven end-to-end needs an external DisplayPort display.

**Deliberately not used — these drive the link, and a wrong value can wedge the only attached
display:** `IODPDeviceWriteDPCD`, `IODPControllerSetLaneCount` / `SetLinkRate` / `SetMin*` / `SetMax*` /
`SetDriveSettings` / `SetScramblingInhibited` / `SetQualityPattern` / `SetSupports*`,
`IODPServiceRetrainLink`, `IOAVServiceRetrainFRL` / `SetFRLMaxRate` / `SetFRLMinRate` /
`SetFRLRecovery`. All of them resolve on macOS 27.0.1 — resolving is not permission to call them.

**Tiling has no symbol.** `IODPDeviceGetTiling`, `IOAVVideoLinkTiling` and `IOAVDisplayTiling` all
fail to resolve, and nothing matching `tiling` appears in the tbd. That facet is reachable only by
decoding raw DPCD over AUX via `IODPDeviceReadDPCD` — a different, and here untested, job.

**Outstanding unknown — signatures.** The tbd yields names, not prototypes, and the on-disk framework
is `Resources` + `_CodeSignature` only (the code lives in the dyld shared cache), so a disassembly
pass needs that image extracted from the cache first. Until then, treat only the prototypes already
declared in `fbd_private_api.h` as known. **Nothing in this section has been *called*** — every claim
is symbol resolution. Per the row's own plan, the pure DPCD/DSC byte parsers should land first: they
are unit-testable with no hardware and no AUX traffic, which is where most of the value and the risk
sit.

## Signatures recovered from the dyld shared cache — 2026-10-14

The DPCD family was located but its **signatures** were not, and that is what blocked
reading anything. They can be read off this machine after all; the earlier search came
up empty because of the tool, not the data. `nm` cannot parse a shared cache (`not
recognized as a valid object file`), but the cache **retains symbol tables**, so LLDB
resolves a cache-resident symbol by name and disassembles it:

```
xcrun lldb --batch \
  -o "run list" \
  -o "image lookup -n IODPDeviceReadDPCD" \
  -o "disassemble -n IODPDeviceReadDPCD" \
  -o "quit" ./.build/debug/fbdcli
```

`image lookup` is what showed these are real and addressable — `IODPDeviceReadDPCD` sits
at `IOKit[0x184d8b0d0]` (`__TEXT.__text + 130744`). What follows are **prototypes** read
from register usage, which is an interface fact rather than code: no instruction
sequence or decompilation is reproduced here.

| Symbol | Arity | Evidence |
|---|---|---|
| `IODPDeviceGetRevisionMajor` | 1 argument → 32-bit | `ldr w0, [x0, #0x24]` then `ret` |
| `IODPDeviceReadDPCD` | 4 arguments | `w1` stored as an address; `cmp w3, #0x1000` then `csel`, so the length clamps at 4096 — the DPCD read cap |
| `IODPDeviceWriteDPCD` | 4 arguments | the mirror of the above with the same clamp. **The one never to call** |
| `IOAVServiceCopyProperties` | 1 argument → copy | `ldr w0, [x0, #0x10]`; a conventional Copy-returning getter over an opaque handle |
| `IOAVVideoLinkBandwidth` | 1 argument | `ldr w19, [x0, #0x6c]`, then `lsr x9, x9, #16` — the AV family's 16.16 fixed-point arithmetic |
| `IODPLinkBandwidth` | 2 arguments | compares `x1` against `0x2540BE400`, `0x324A9A700`, `0x4A817C800` — 10, 13.5 and 20 Gbps, i.e. UHBR10 / 13.5 / 20 |

So row #24's read path is now **signature-known**: `IODPDeviceReadDPCD(device, address,
buffer, length)`, capped at 4096 bytes, reachable after `IODPDeviceCreateWithService` on
the same `IOService` the DDC path already finds. **Nothing has been called.** This
removes the "signatures unknown" blocker; it does not remove the caution around a write
to the only attached display.

## The DisplayPort link-data path — located, and deliberately not called (issue #19)

BetterDisplay 5 reads the DisplayPort link data (DPCD / DSC / link bandwidth / tiling)
through a pair of IOKit entry points that BetterDisplay 4.3.5 did not use. Both are
exported by the **public** `IOKit.framework`, so they are reached the same way as the
`IOAVService*` set above — the same `dlopen`/`dlsym` pattern, no ObjC runtime.

| Symbol | Measured on macOS 27.0.1 | What it is |
|---|---|---|
| `IOAVVideoInterfaceCreateWithService` | resolves (`dlsym`) | the video-interface wrapper for a display's service |
| `IOAVVideoInterfaceGetLinkData` | resolves (`dlsym`) | the link-data read — **structure not publicly described** |
| `IOAVVideoInterfaceGetLinkDataWithSource` | resolves (`dlsym`) | the same, with the source |
| `IOAVServiceGetLinkData` / `WithSource` | resolve (`dlsym`) | the service-level equivalent |
| `IOAVVideoInterfaceCopyProperties` / `CopyDisplayAttributes` | resolve (`dlsym`) | the video-interface property dictionaries |
| `IOAVServiceCopyProperties` / `CopyProperty` | resolve (`dlsym`) | the service property dictionaries |

**Resolved is not called.** Three things stopped the call, and all three are measured:

1. **The return structure of `IOAVVideoInterfaceGetLinkData` is not statically visible.**
   No public header describes it, and the framework lives in the dyld shared cache, so a
   field could only be guessed at. A guessed bandwidth or DSC flag in a bug report is
   worse than no number at all, so FBD reports those fields as unavailable.
2. **`IOAVVideoInterfaceCreateWithService` raised a kernel trap (SIGTRAP)** when handed
   this repository's machine's only display node (`AppleCLCD2` / `DCPAVServiceProxy`).
   `IOAVServiceCreateWithService` traps on the same nodes. Creating an interface is
   therefore not free, and the machine has no external display attached to try it on.
3. **The supporting keys are not in the CoreDisplay info dictionary.** Measured on the
   built-in panel: `CoreDisplay_DisplayCreateInfoDictionary` returns 40+ keys, and none
   of `_connectionMode`, `_connectionTypeDescription`, `_connectionStatusActiveProbe`,
   `_tunnelControlDescription`, `_lastCECReport`, `_hdmiInputCount` or `_macInputNumber`
   is among them. They belong to the AV video-interface / service property dictionary,
   which is exactly the dictionary the unreachable entry point would produce.

So FBD declares a **probe only** — `FBDVideoLinkDataAvailable()` in
`Sources/CPrivateAPI/fbd_linkdata.c`, wrapped by `VideoLinkDataAPI` in
`Sources/FBDCore/PrivateAPI/`. It answers one question safely: *is the entry point present
on this macOS at all?* A report can then say "present here, but its result cannot be
read", which is a very different statement from "this feature does not exist".

| API | How verified | macOS versions |
|---|---|---|
| `IOAVVideoInterfaceCreateWithService` / `IOAVVideoInterfaceGetLinkData` | `dlsym` against a live `dlopen` of `IOKit.framework` — **resolution only, never called** | 27.0.1 |

The link facts therefore appear in every report as **unavailable, with the reason**:
"IOAVVideoInterfaceGetLinkData resolves here but returns a structure that no public
header describes, so its fields cannot be read safely". The connection facts
(`_connectionMode` and friends) appear as unavailable for the related reason that the
dictionary holding them is never read.

What the report *does* carry is what can be measured: the DPCD capability block read
over AUX through `IODPDeviceReadDPCD` (already declared above, and already the subject of
`fbdcli dpcd`), the DSC block inside it, the lane-status registers, and the
**capability bandwidth** computed from the sink's maximum link rate and lane count. Tiling
has no symbol at all and FBD does not decode the DPCD tiling registers, so tiling is
reported as unavailable too.

## Mode creation does not exist (rows #22, #27)

Those rows were carried as "symbol unsettled". Settled: **absent**. `SLSAddDisplayMode`,
`SLSDisplayModeDescription` and `SLSSetDisplayMode` return zero matches on macOS 27,
checked the same way as above; only `SLSConfigureDisplayMode` exists, and FBD already uses
it through `CGSAPI`. Creating a display mode needs a *different* mechanism from the one
those rows' route assumed, so they are blocked on design rather than on a name.

## DDC/CI transport — audited component by component

`docs/ddc-equivalence.md` compares FBD's DDC/CI transport with the transport of
[didriksg/Crisp](https://github.com/didriksg/Crisp) v1.7.1 (`242a8ce`), component by
component: the private symbol, the wire framing, the reply validation, the read cache, the
read quarantine, the write cadence, the bus contention and the display↔channel matching.

The claim it supports is **code-verified equivalence**, never hardware verification: FBD's
DDC path has not been exercised against a real DDC monitor in this repository (issue #7).
The symbols it relies on are the ones already listed above — `IOAVServiceCreateWithService`,
`IOAVServiceReadI2C`, `IOAVServiceWriteI2C` — and no new private symbol was declared for the
hardening work (issue #25).

## HiDPI override — the re-enumeration needs no private symbol

The HiDPI ladder feature (issue #27) writes a `scale-resolutions` override and then asks the
window server to re-read the display. That last step needs `IOServiceRequestProbe`, which
looked like a private symbol when the work was scoped. It is not: it is declared in the
public SDK (`IOKit/IOKitLib.h`), next to `IODisplayCreateInfoDictionary`
(`IOKit/graphics/IOGraphicsLib.h`) and `kIODisplayOnlyPreferredName`. FBD calls both
directly from `Sources/FBDCore/PrivateAPI/IOServiceProbeAPI.swift` — the folder name is
about the layer, not about the symbols.

So the HiDPI ladder adds **no** entry to the table above. The privileged part of the feature
(`do shell script "…" with administrator privileges`) is not a private API either: it is the
documented, user-visible administrator prompt. ADR 0005 records why the command model is
kept separate from that executor.

The claim this feature supports is *implemented, not yet verified on hardware*: no display
with a HiDPI ladder has been re-enumerated through this path in this repository.

## Live-verified on this machine — 2026-10-20

Everything in this section was **measured** on this machine (M1 Max, macOS 27.0.1,
built-in XDR panel), not taken from a header comment, from another project or from
a release note:

- **Apple brightness** — `DisplayServices`: read 46.7 %, wrote 60 %, read 60 %, restored 46.7 %.
- **Resolution** — 132 modes enumerated; the current mode re-applied through the mode write path.
- **Night Shift** — strength 50 % → 0 % → 50 %, read back after each write.
- **Display presets** — the built-in XDR panel switched preset 0 → 1 → 0, read back after each switch.
- **Virtual screens** — the app created a virtual screen from a persisted config at launch (`SLVirtualDisplay`).
- **Software overlay** — a full-screen filter applied and cleared (the overlay the below-floor blend and the software boost ride on).
- **OSD** — the transient HUD showed.
- **PiP** — ScreenCaptureKit enumerated the displays, windows and apps (the stream itself was not started).
- **True Tone** — `CBTrueToneClient`: `available` true, `enabled` read back, `setEnabled:` round-tripped (off → on, read back after each write).
- **HiDPI override** — the generated install script ran against a temporary root: the plist is written, `plutil -lint` accepts it, a repeated install is byte-identical and leaves no staging file behind, and the removal takes exactly that file away (`Tests/FBDCoreTests/HiDPIOverrideInstallScriptTests.swift`).

Two measured facts that change a claim made elsewhere:

- The **True Tone** row above was inherited from a note in Lunar's `CBTrueToneClient.h`
  ("not controllable from third parties since macOS 26.3"). Measured here, `setEnabled:` is
  accepted and reads back, so the note does not hold on this macOS: FBD's toggle is live-verified.
- The **XDR native preset rewrite** is refused on macOS 26 and later. The controller's own
  self-test detects the rejected write (`XDRNativeController.setUpscaleTarget` returns false),
  so the upscaling falls back to the software boost overlay — which needs Screen Recording and
  lives in an overlay session that does not outlive a one-shot `fbdcli` run.

Still unverified here, because this machine cannot show them: DDC/CI on an external monitor
(issue #7), EDID on the built-in panel (macOS 27 exposes none), the below-floor blend's DDC
floor, the remembered-disconnect / docked-built-in / ambient-sync behaviours (they need an
external display), and the privileged HiDPI write to `/Library/Displays` together with the
display re-enumeration.

## Notes

- **Nothing new was added to this ledger by the BetterDisplay-parity work.** Every new controller seam
  in that change is built on public APIs plus symbols already listed above: the brightness model
  uses the existing `DisplayServices`/`SkyLight` paths through `CombinedBrightness` and
  `XDRBoostPlanner`, configuration protection re-applies through `ResolutionController`,
  `SkyLightAPI` and `DisplayController`, connection management goes through the existing
  `CGSConfigureDisplayEnabled` chokepoint, and the reminder of the change (safe mode, lock dim,
  mode favourites, keyboard-control target, group sync policy) is pure logic over `Settings`.
  No private symbol was newly declared, so there is nothing to record here — this note exists so a
  future reader does not go looking for a missing entry.

- ObjC classes are always reached via `NSClassFromString` + runtime messaging (never static link). Class names verified at runtime via `NSClassFromString` on macOS 27.
- `VirtualDisplay.framework` does not exist on macOS 27 beta — Tier 3 must use the SidecarCore path there.
- DDC (IOAVService) is Apple Silicon only and **does not work under Rosetta** — guarded by `IOAVServiceAPI.isAppleSilicon`. The transport's reply validation, read cache, read quarantine and topology hold are audited against didriksg/Crisp v1.7.1 in `docs/ddc-equivalence.md`.
- **Built-in display disconnect is a hardware hazard, not an API one.** On Macs with the base M3 chip (M3 MacBook Air, entry-level M3 MacBook Pro) Apple repurposed the built-in panel's connection for clamshell two-display support, so a soft-disconnected built-in display may not come back without a reboot. `CGSConfigureDisplayEnabled` is fine there; the machine is not. `BuiltInDisconnectGuard` refuses the disconnect on that hardware unless `Settings.allowBuiltInDisconnectOnAffectedMacs` is set. BetterDisplay ships the same guard (`_displayAllowDisconnectM3Builtin`, waydabber/BetterDisplay#4723).
- **Mode capability queries are declared and wired** — `SLSGetDisplayModeMinRefreshRate`, `SLSIsDisplayModeVRR`, `SLSIsDisplayModeProMotion` (Tier 2→3, live-verified on macOS 27). Two traps worth keeping:
  - The mode argument is an **`IODisplayModeID`** (`CGDisplayCopyDisplayMode(_:).ioDisplayModeID`), **not** the CGS `displayModeNumber` that `CGSGetDisplayModeDescriptionOfLength` reports. A wrong number returns 0/false silently rather than erroring, so a bad mapping is indistinguishable from "this display has no VRR".
  - The queries require a **live WindowServer connection** and **crash a process that has none** — observed as signal 11 under xctest. They are therefore queried on demand (once per `fbdcli info`) and deliberately *not* stored on every `DisplayMode`, because populating models is a path the test suite exercises.
- Direct linkage of `DisplayServices`/`SkyLight` uses `-F/System/Library/PrivateFrameworks` unsafeFlags in `Package.swift` (same pattern as lunar/displayplacer).
