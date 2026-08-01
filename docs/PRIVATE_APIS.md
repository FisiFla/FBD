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

## Not yet declared (Tier 2+)

| API | Purpose | Tier |
|---|---|---|
| `SLSDisplayGetPresetCount / CopyPreset / CopyPresetData / SetPreset / SetPresetData / GetActivePresetIndex / SetActivePresetIndex` | native XDR upscaling (preset rewrite) | 2 |
| Preset data keys: `PresetHostMaxPotentialEDRHeadroom`, `PresetMaxHDRLuminance`, `PresetMaxSDRLuminance`, `PresetSDRMaxNits`, `PresetHostMaxSliderBrightness`, `PresetHostMinSliderBrightness`, `PresetHostReferenceColor` | verified in BetterDisplay strings | 2 |
| `SLSDisplayIsHDRModeEnabled / SetHDRModeEnabled / SupportsHDRMode` | forced HDR mode / 16-bpc extended luminance | 2 |
| `IOMobileFramebufferOpen`, `IOMobileFramebufferSetColorRemapMode` | direct built-in XDR (color-table method) | 2 |
| `SLSDisplaySetUnderscan`, `SLSGetDisplayModeMinRefreshRate`, `SLSIsDisplayModeProMotion / VRR`, `SLSSetDisplayRotation` | underscan, VRR/ProMotion metadata, rotation | 1→2 (partially Tier 1: VRR detection planned) |
| `IOAVServiceSetVirtualEDIDMode` | EDID override (Apple Silicon) | 4 |
| `CGVirtualDisplay*` classes (`VirtualDisplay.framework`, dlopen — absent on macOS 27) + SidecarCore `SidecarDisplayManager` | virtual displays | 3 |
| `ColorSyncDeviceSetCustomProfiles` | color profiles / HDR color mode | 4 |
| `CBBlueLightClient`, `CBTrueToneClient` (CoreBrightness, ObjC runtime lookup) | Night Shift / True Tone | 5 |

## Notes

- ObjC classes are always reached via `NSClassFromString` + runtime messaging (never static link). Class-name strings verified in the BetterDisplay binary.
- `VirtualDisplay.framework` does not exist on macOS 27 beta — Tier 3 must use the SidecarCore path there.
- DDC (IOAVService) is Apple Silicon only and **does not work under Rosetta** — guarded by `IOAVServiceAPI.isAppleSilicon`.
- Direct linkage of `DisplayServices`/`SkyLight` uses `-F/System/Library/PrivateFrameworks` unsafeFlags in `Package.swift` (same pattern as lunar/displayplacer).
