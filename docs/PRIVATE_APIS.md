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
| `SLSDisplayCopyActivePreset(display)` | ✅ returns active preset dict | SkyLightAPI |
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
| Sparkle 2.9.4 (public, SPM) | ✅ linked; feed URL configurable, off by default | UpdaterController |
| `CoreDisplay_DisplayCreateInfoDictionary` | ✅ live-verified (rich display info; no IODisplayEDID for built-in panel on macOS 27) | EDIDController fallback |

## Not yet declared (Tier 3+)

| API | Purpose | Tier |
|---|---|---|
| `SLSDisplaySetUnderscan`, `SLSGetDisplayModeMinRefreshRate`, `SLSIsDisplayModeProMotion / VRR`, `SLSSetDisplayRotation` | underscan, VRR/ProMotion metadata, rotation | 2→3 |
| `IOAVServiceSetVirtualEDIDMode` | EDID override (Apple Silicon) | 4 |
| `CGVirtualDisplay*` classes (`VirtualDisplay.framework`, dlopen — absent on macOS 27) + SidecarCore `SidecarDisplayManager` | virtual displays | 3 |
| `ColorSyncDeviceSetCustomProfiles` | color profiles / HDR color mode | 4 |
| `CBBlueLightClient`, `CBTrueToneClient` (CoreBrightness, ObjC runtime lookup) | Night Shift / True Tone | 5 |

## Notes

- ObjC classes are always reached via `NSClassFromString` + runtime messaging (never static link). Class-name strings verified in the BetterDisplay binary.
- `VirtualDisplay.framework` does not exist on macOS 27 beta — Tier 3 must use the SidecarCore path there.
- DDC (IOAVService) is Apple Silicon only and **does not work under Rosetta** — guarded by `IOAVServiceAPI.isAppleSilicon`.
- Direct linkage of `DisplayServices`/`SkyLight` uses `-F/System/Library/PrivateFrameworks` unsafeFlags in `Package.swift` (same pattern as lunar/displayplacer).
