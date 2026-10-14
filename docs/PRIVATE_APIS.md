# FBD — Private API registry

Every private API used by FBD, its verification source, and the tier that consumes it.
Signatures were verified against the macOS 27 dyld export trie (`dyld_info -exports`),
the BetterDisplay v4.3.5 binary (imports/strings), and FOSS implementations (lunar, displayplacer).

## Declared in `Sources/CPrivateAPI/include/fbd_private_api.h`

| API | Source | Used by | Tier |
|---|---|---|---|
| `CGSGetDisplayList` | displayplacer | CGSAPI | 1 |
| `CGSGetCurrentDisplayMode` | displayplacer | CGSAPI / ResolutionController | 1 |
| `CGSGetNumberOfDisplayModes` | displayplacer | CGSAPI | 1 |
| `CGSGetDisplayModeDescriptionOfLength` (struct `CGSDisplayModeDescription`, 212 B) | displayplacer `CDStructures.h` | CGSAPI | 1 |
| `CGSConfigureDisplayMode` | displayplacer | CGSAPI / ResolutionController | 1 |
| `CGSConfigureDisplayEnabled` | displayplacer, BetterDisplay imports | (declared; used in Tier 3 soft-disconnect) | 3 |
| `DisplayServicesGetBrightness / SetBrightness` | lunar Bridge.h, dyld exports | DisplayServicesAPI / AppleController | 1 |
| `DisplayServicesGetLinearBrightness / SetLinearBrightness` | lunar Bridge.h | AppleController | 1 |
| `DisplayServicesCanChangeBrightness` | lunar Bridge.h | AppleController | 1 |
| `DisplayServicesHasAmbientLightCompensation` | lunar Bridge.h | AppleController | 1 |
| `DisplayServicesAmbientLightCompensationEnabled / EnableAmbientLightCompensation` | lunar Bridge.h | AppleController | 1 |
| `DisplayServicesResetAmbientLight` | lunar Bridge.h | (declared; auto-brightness reset) | 2 |
| `DisplayServicesRegisterForBrightnessChangeNotifications` (+unregister) | lunar Bridge.h | (declared; brightness sync owns a global registry) | 2 |
| `IOAVServiceCreateWithService` | BetterDisplay imports (IOKit dyld exports) | IOAVServiceAPI / ExternalController | 1 |
| `IOAVServiceReadI2C / WriteI2C` | BetterDisplay imports, lunar arm64 path | IOAVServiceAPI / DDCController | 1 |
| `IOAVServiceCopyEDID` | BetterDisplay imports | IOAVServiceAPI (Tier 4 EDID) | 4 |
| `SLSMainConnectionID` | yabai/skhd headers | SkyLightAPI | 1 |
| `SLSDetectDisplays` | BetterDisplay imports | SkyLightAPI / ResolutionController | 1 |

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
| `CBTrueToneClient`: `available`, `enabled`, `setEnabled:` | available=false on macOS 26.3+ (degrades) | TrueToneController |
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

## DisplayPort link / DPCD / DSC — located 2026-10-14 (gap-matrix row #24, reports row #30)

Row #24 was blocked on *identifying* these symbols. They are **all exported by the public
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

## Mode creation does not exist (rows #22, #27)

Those rows were carried as "symbol unsettled". Settled: **absent**. `SLSAddDisplayMode`,
`SLSDisplayModeDescription` and `SLSSetDisplayMode` return zero matches on macOS 27,
checked the same way as above; only `SLSConfigureDisplayMode` exists, and FBD already uses
it through `CGSAPI`. Creating a display mode needs a *different* mechanism from the one
those rows' route assumed, so they are blocked on design rather than on a name.

## Notes

- **Nothing new was added to this ledger by the BetterDisplay-parity work** (branch
  `feat/betterdisplay-parity` → see `docs/plans/fbd-parity-progress.md`). Every new controller seam
  in that change is built on public APIs plus symbols already listed above: the brightness model
  uses the existing `DisplayServices`/`SkyLight` paths through `CombinedBrightness` and
  `XDRBoostPlanner`, configuration protection re-applies through `ResolutionController`,
  `SkyLightAPI` and `DisplayController`, connection management goes through the existing
  `CGSConfigureDisplayEnabled` chokepoint, and the reminder of the change (safe mode, lock dim,
  mode favourites, keyboard-control target, group sync policy) is pure logic over `Settings`.
  No private symbol was newly declared, so there is nothing to record here — this note exists so a
  future reader does not go looking for a missing entry.

- ObjC classes are always reached via `NSClassFromString` + runtime messaging (never static link). Class-name strings verified in the BetterDisplay binary.
- `VirtualDisplay.framework` does not exist on macOS 27 beta — Tier 3 must use the SidecarCore path there.
- DDC (IOAVService) is Apple Silicon only and **does not work under Rosetta** — guarded by `IOAVServiceAPI.isAppleSilicon`.
- **Built-in display disconnect is a hardware hazard, not an API one.** On Macs with the base M3 chip (M3 MacBook Air, entry-level M3 MacBook Pro) Apple repurposed the built-in panel's connection for clamshell two-display support, so a soft-disconnected built-in display may not come back without a reboot. `CGSConfigureDisplayEnabled` is fine there; the machine is not. `BuiltInDisconnectGuard` refuses the disconnect on that hardware unless `Settings.allowBuiltInDisconnectOnAffectedMacs` is set. BetterDisplay ships the same guard (`_displayAllowDisconnectM3Builtin`, waydabber/BetterDisplay#4723).
- **Mode capability queries are declared and wired** — `SLSGetDisplayModeMinRefreshRate`, `SLSIsDisplayModeVRR`, `SLSIsDisplayModeProMotion` (Tier 2→3, live-verified on macOS 27). Two traps worth keeping:
  - The mode argument is an **`IODisplayModeID`** (`CGDisplayCopyDisplayMode(_:).ioDisplayModeID`), **not** the CGS `displayModeNumber` that `CGSGetDisplayModeDescriptionOfLength` reports. A wrong number returns 0/false silently rather than erroring, so a bad mapping is indistinguishable from "this display has no VRR".
  - The queries require a **live WindowServer connection** and **crash a process that has none** — observed as signal 11 under xctest. They are therefore queried on demand (once per `fbdcli info`) and deliberately *not* stored on every `DisplayMode`, because populating models is a path the test suite exercises.
- Direct linkage of `DisplayServices`/`SkyLight` uses `-F/System/Library/PrivateFrameworks` unsafeFlags in `Package.swift` (same pattern as lunar/displayplacer).
