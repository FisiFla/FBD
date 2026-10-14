# BetterDisplay feature inventory (reference)

Reference application: **`/Applications/BetterDisplay.app` — 5.1.1, build 53784**, arm64, macOS 27.
Read-only oracle; not patched, re-signed or modified. Research date: 2026-10-14.

Purpose: establish, from evidence, *which features BetterDisplay has* — so FBD's gap analysis
compares against a real list instead of a guess.

> **Wording policy.** FBD is public and MIT, so this document **paraphrases** BetterDisplay's
> user-facing wording instead of quoting it. What is reproduced verbatim is limited to
> (a) **CLI parameter names** — API identifiers, which the plan itself enumerates and which
> cannot be paraphrased without becoming useless, and (b) short **navigation identifiers**
> (pane names, generic technical terms). Every feature description below is written in my own
> words. The raw, un-paraphrased labels live **outside this repository** in the AX dumps at
> `~/Downloads/bd_poc/bd-ui-reference/` — see the evidence key.

---

## Evidence key

| Tag | Source | What it is |
|---|---|---|
| **S1** | Live Settings walk | AX tree + screenshot of every Settings pane and every sheet, driven live this session. Dumps in `~/Downloads/bd_poc/bd-ui-reference/{displays-*,pane_*,sheet_*}.txt`. |
| **S2** | Live app menu | AX enumeration of the status-item quick menu (`appmenu_top.txt`) plus the Stream Display flyout, this session. |
| **C1** | CLI integration reference | Output of `"$BD" help` — the authoritative operation + parameter list, captured verbatim to `$TMPDIR/bd_help.txt`. |
| **C2** | CLI `get` probe | `get -<param>` for **268 of the 271** documented parameters, this session. 113 returned a live value, 155 returned nothing, **0 timed out**. Results in `$TMPDIR/bd_cli_probe.tsv`. |
| **C3** | CLI round-trip | `set` then `get` on 5 safe parameters, live, with restoration. `$TMPDIR/bd_cli_roundtrip.txt`. |
| **L** | Localisation catalog | `Contents/Resources/en-GB.lproj` catalog: 2563 keyed entries, 2600 distinct values. The "intent" layer. |
| **P** | Prior-session dump | Same-day, same-build AX dumps from the earlier RE session (`/tmp/bd_lldb/sw2_*.txt`, `sheets.txt`, `ax2_tree.txt`). Used only for submenu bodies and as a cross-check. |

Cross-checking: every area below is corroborated by **at least two** independent tags, and the
CLI (`C1`+`C2`+`C3`) is preferred wherever a feature's *behaviour* is what matters.

---

## A. Display control — brightness stack, volume, DDC

| feature | what it does | evidence | notes |
|---|---|---|---|
| Brightness, method auto-selected | Sets brightness, picking whichever control path suits the display | C1 `brightness`; C2 → `0.855` | Device-specific. |
| Hardware brightness | Forces the Apple or DDC hardware path specifically | C1 `hardwareBrightness`; C2 → `0.804` | |
| Software brightness / dimming | Forces the purely-software dimming path; also reported in nits | C1 `softwareBrightness`, `softwareBrightnessNits`; C2 → `1.0`, `500.0` | Works even with no hardware support. |
| Combined brightness | One user-facing curve spanning hardware brightness, software dimming and XDR/HDR upscaling | C1 `combinedBrightness`; C2 → `0.855`; S1 display page (a "combined brightness" checkbox + an info line) | FBD has the same concept (`CombinedBrightness`). |
| Brightness in nits | Reads/sets brightness as absolute luminance | C1 `brightnessNits`, `hardwareBrightnessNits`; C2 → `307.25` | |
| Editable nits ranges | Lets the user hand-enter the nits value at hardware min/max, and the HDR-mode peak SDR and peak HDR luminance | S1 `sheet_Configure_Brightness_Nits_Ranges` | Values seen: hardware min 4, max 500; HDR peak SDR 500; HDR peak HDR 1600. |
| Software brightness upscaling (XDR/HDR) | Raises brightness above 100 % by software means | C1 `brightnessUpscaling`; C2 → `off`; S1 display page section | Marked experimental in-app. |
| Direct brightness upscaling | The built-in-XDR variant of the above | C1 `directBrightnessUpscaling`; L names the direct/Apple-XDR variants | |
| Combined-curve tuning | Three tuning knobs: where software dimming takes over, the top of the upscaling scale, and the lowest permitted hardware level | S1 `sheet_Image_Adjustment_Settings` | Prevents the curve from being discontinuous at the swap points. |
| Re-define the 0 % software-brightness point | Compresses the usable software range so 0 % is not absolute black | S1 `sheet_Image_Adjustment_Settings` | |
| Dim on screen saver / lock | Drops brightness to a chosen level when the screensaver starts or the screen locks | S1 display page | Marked experimental. |
| Volume and mute | Display volume / mute where the display exposes DDC audio, or via a matched native audio device | C1 `volume`, `mute`; S1 `sheet_Volume_Control` (availability report + audio-device association + optional volume OSD) | FBD has DDC volume/mute. |
| Hardware contrast | DDC contrast control | C1 `hardwareContrast` | |
| Hardware RGB black level and gain | Six DDC controls: per-channel black level and per-channel video gain | C1 `redHardwareBlackLevel` … `blueHardwareGain` | Preview of "black-level (RGB) hardware controls" from Appendix B. |
| Input switching | List and switch the device's input source | C1 `changeInputSource`, `inputSourceList`; L names a configurable per-display input list | |
| Hardware backlight on/off, power-off, factory reset | Screen-off via DDC/smart protocol; power-off; restore the display's factory defaults | C1 `hardwareBacklight`, `hardwarePowerOff`, `hardwareFactoryReset` | |
| Raw DDC access + capabilities | Sends an arbitrary VCP read/write; reports the display's DDC capability string and parses it | C1 `ddc`, `ddcAlt`, `vcp`, `ddcCapabilities`, `ddcCapabilitiesString`; L enumerates the full VCP name space | `vcp` alone names ~150 VCP codes. |
| Ambient light | Reads the display's ambient-light sensor | C1 `ambientLight`; C2 → `90.0` | |
| Auto brightness (Apple displays) | Toggles the OS ambient-light auto-brightness | C1 `autoBrightness`; C2 → `on`; S1 "Device control settings" sheet | |
| Night Shift / True Tone / Dark Mode | System colour-comfort toggles, plus a Night Shift strength value | C1 `nightShift`, `nightShiftValue`, `trueTone`, `darkMode`; C2 → `off`, `0.5`, `on`, `on`; C3 round-tripped `nightShiftValue` | Also a setting to suppress Night Shift while HDR is active. |
| OSD | Basic native OSD, custom OSD, and third-party OSD-integration notifications | C1 `osdShowBasic`, `osdShowCustom`, `osdIntegrationNotification`; C3 round-tripped `osdShowCustom`; L has OSD style/location/rounding/segment options | FBD has a custom OSD. |
| Underscan | Underscan control for displays whose framebuffer supports it | C1 `underscan`; S1 `sheet_Image_Adjustment_Settings` (a force-enable escape hatch) | |
| GPU dithering | Enables GPU dithering | C1 `gpuDithering`; C2 → `on` | Apple silicon only. |
| Turn the screen off / full dim on disconnect | Screen-off and a "fully dim when the display disconnects" behaviour | L names both | |
| Device-controller selection | A display is a *device* with a set of controllers attached; the user adds/removes them | S1 `sheet_Add_or_Remove_Controllers`; C2 `configuredControllerList` → `AppleController`, `AmbientLightController`, `IntegrationController`, `CompositorFilterController`, `CombinedController` | This is the architecture FBD mirrors with its own controller seams. |
| Prefer hardware brightness; generic third-party treatment; startup value policy | Three device-control policy switches: prefer hardware over software, treat an Apple-made panel as generic so DDC can be enabled, and choose whether stored control values are assumed valid, written, or read back | S1 `sheet_Device_control_settings` | FBD has the DDC cooldown/retry equivalents but not these policies. |

## B. Colour

| feature | what it does | evidence | notes |
|---|---|---|---|
| Colour mode / HDR colour mode | Reports and controls the display's colour mode, including the HDR variant | L; C1 `connectionMode`; C2 → `… 3456x2234 120.00Hz Variable 8bit SDR RGB Full P3` | |
| Colour depth | Bits per channel | C1 `colorDepth`; C2 → `10` | |
| Connection mode (low level) | Chooses the exact link mode by bpc / range / encoding / chroma / HDR flavour, with list endpoints to discover valid combinations | C1 `connectionMode`, `connectionModeList`, `connectionModeListAll`, `preferredConnectionMode`; C2 returned real lists | Described in-app as risky; Apple silicon + natively connected displays only. |
| Colour profile | Applies / resets a display colour profile, lists installed profiles, opens ColorSync | C1 `colorProfileURL`, `colorProfileReset`, `installedColorProfileURLs`; C2 returned the system profile URL list | FBD has `ColorProfileController`. |
| Colour table control | Applies colour-related adjustments (and software XDR) through the framebuffer colour table | S1 display page + `sheet_Image_Adjustment_Settings`; L | FBD's equivalent is entitlement-gated on macOS 27 (documented in `docs/PRIVATE_APIS.md`). |
| Compositor filter layer | Applies adjustments through an overlay/compositor filter instead | S1 display page; L | FBD's `OverlayController` is this. |
| Software image adjustments (colour table) | Per-RGB gamma, per-RGB gain, a master gamma/gain, colour temperature, quantization, contrast | C1 `gamma`, `rGamma`/`gGamma`/`bGamma`, `gain`, `rGain`/`gGain`/`bGain`, `temperature`, `quantization`, `contrast` | |
| Software image adjustments (compositor filter) | Saturation, hue, highlight, shadow, vibrance, sepia, vignette, gaussian blur, sharpen-luminance, unsharp mask, edges, bloom, gloom, noise reduction, motion blur, plus a large set of artistic filters (pixellate, crystallize, hexagonal pixellate, pointillize, dot screen, hatched screen, line screen, CMYK halftone, monochrome, thermal, x-ray, comic, median) | C1 lists ~40 `filter*` parameters; C2 returned current values for all of them | FBD ships contrast/saturation/gamma/temperature/invert/sharpen/zoom-pan/LUT — see the gap matrix. |
| Photo effects and blend modes | Applies a photo-effect look and/or a blend mode to the filter overlay | C1 `videoFilter` (documents `photoEffect`, `blendMode`, and their enable switches); L names each effect/blend mode | |
| Custom 3D LUT filters | Imports and manages reusable CUBE files as named filters | L; C1 `videoFilter` documents `custom:<name>` | FBD has `LUTCubeParser` + `--lut`. |
| Invert colours | Colour inversion as a first-class toggle | C1 `inverted`; C2 → `off` | |
| Framebuffer colour mapping | Switches the framebuffer between normal, inverted, grayscale and inverted-grayscale | C1 `standardFramebuffer`, `invertedFramebuffer`, `grayscaleFramebuffer`, `invertedGrayscaleFramebuffer` | Apple silicon only; FBD had an entitlement-gated probe here. |
| Hide overlays from capture | Keeps overlay-based adjustments out of screenshots and screen recordings | S1 display page | |
| Suspend image adjustments | Temporarily suspends all software adjustments except brightness | C1 `suspendImageAdjustments`; C2 → `off` | |
| Reset colour adjustments | Clears all software image adjustments | C1 `resetColorAdjustments` | |
| Force colour-table support; HDR clipping guard | Escape hatches for displays where the colour table is unavailable, and a guard against clipping HDR content | L | |
| Uniformity correction | Per-panel uniformity compensation | L | |

## C. Resolution, timing and layout

| feature | what it does | evidence | notes |
|---|---|---|---|
| Resolution list | Lists and applies modes, including HiDPI and scaled variants | C1 `resolution`, `displayModeList`; C2 → `1728x1117`, and a full mode list | |
| HiDPI toggle | Switches between the LoDPI and HiDPI variants of the current resolution | C1 `hiDPI`; C2 → `on` | |
| Refresh rate, incl. unexposed rates and VRR | Applies a refresh rate, including NTSC-style unexposed rates, and reports VRR/ProMotion state | C1 `refreshRate`, `refreshRateList`; C2 → `ProMotion` and a list `ProMotion, 60Hz, 59.94Hz, 50Hz, 48Hz, 47.95Hz` | FBD exposes mode-based refresh rates; the *unexposed* list is a gap. |
| Display mode number | Applies a mode by raw mode number | C1 `displayModeNumber`; C2 → `54` | |
| Favourite modes | Saves the current mode into one of five slots and recalls it | C1 `favoriteMode`, `saveFavoriteMode`; L | FBD has no mode favourites. |
| Flexible scaling | Generates a fine-grained list of resolutions at the panel's aspect ratio so GUI scale can be slid smoothly | S1 display page "System Configuration and Flexible Scaling"; L | FBD's ADR/roadmap lists this as unrealised ("custom CGS mode creation needs the private mode-list API"). |
| Custom scaled resolutions | Adds user-defined scaled resolutions, as both LoDPI and HiDPI where possible | S1 display page; L | |
| Edit native / default resolution, system display name, display role | Rewrites the display's system configuration: its native pixel resolution, its default resolution, its system-wide name, and whether macOS treats it as a monitor or a television | S1 `sheet_More_system_configuration_options`; L | FBD's roadmap lists this as future. |
| Resolution slider presentation | Shows the resolution slider as a percentage for scalable displays, or as a magnification slider | S1 pane Menu; L | |
| Notch / ears | Toggles the notched-screen area for modes that have both variants | C1 `notch`; C2 → `on` | FBD has a notch toggle. |
| Rotation | Rotates in 90° steps, with extra options for the internal display and shortcut-as-toggle behaviour | C1 `rotation`; C2 → `0`; L | FBD has rotation (returns 1001 for the built-in on macOS 27). |
| Placement and relative move | Sets the display's origin, or positions it relative to a named/identified neighbour using direction specifiers | C1 `placement`, `moveTo`; C2 → `0x0` | FBD has `ArrangementMath` + the public CG API (ADR-0002). |
| Mirroring | Mirrors a display to one or more targets, and can enforce that association | C1 `mirror`, `targetTagID`/`targetUUID`/`targetDisplayID`/`targetName`; C2 → `off`; L adds enforced/auto mirroring | |
| Framebuffer bool / numeric properties | Sets arbitrary named framebuffer properties | C1 `framebufferBoolProperty`, `framebufferNumericProperty` | Apple silicon only. |
| Reinitialise display | Re-establishes the connection and reloads configuration, on wake/unlock or on demand | C1 `reinitialize`; S1 `sheet_Additional_settings`; L adds external-only variants | Aimed at displays that misbehave after sleep. |
| Resolution/refresh-range limits | Restricts the resolution slider and keyboard shortcuts to a sub-range | S1 `sheet_Additional_settings` | |
| Mode-list breadth options | Options to show mixed/LoDPI+HiDPI modes together, below-720p modes, above-8K modes, and unsafe/invalid modes | L | |
| Allocation limits, hinted maxima, DSC/capability report | Reports panel/link capability limits and Display Stream Compression state | L; C1 `DSCReport`, `DPCDReport`, `rawDPCD`; C2 returned live DSC/DPCD data | Appendix B asks for "DSC reports" — present. |

## D. Virtual displays, groups and protection

| feature | what it does | evidence | notes |
|---|---|---|---|
| Create / discard virtual screens | Creates a virtual display with a chosen type, or discards one | C1 `create` (`type=VirtualScreen`), `discard`; S1 display Overview "virtual screens" section | FBD has `VirtualScreenController`. |
| Virtual-screen geometry | Name, serial, vendor number, model number, aspect width/height, diagonal size, multiplier step and multiplier min/max, flipping, HiDPI, and an explicit resolution list | C1 `virtualScreenName`, `virtualScreenSerial`, `virtualScreenVendorNumber`, `virtualScreenModelNumber`, `aspectWidth`/`aspectHeight`, `sizeInch`, `multiplierStep`, `limitMultiplierSize`, `multiplierMin*`/`multiplierMax*`, `flipped`, `virtualScreenHiDPI`, `useResolutionList`, `resolutionList` | FBD's virtual screens are creation-form-configured (ADR-0001). |
| Connect / disconnect virtual screens | Connects or disconnects a virtual screen on demand, with auto-connect policies | C1 `connected`; L lists auto-connect-on-quit/startup, connect-all, reconnect-after-wake, and disassociate variants | FBD has connect/disconnect + auto-connect. |
| Associate a virtual screen with real displays | Recalls an arrangement when the virtual screen attaches, and mirrors it to real displays | L | |
| Sidecar displays | Lists and connects Sidecar displays by name or UUID | C1 `sidecarList`, `sidecarConnected` | FBD's roadmap notes the SidecarCore path. |
| Display groups | Creates, duplicates, discards, enables/disables groups of displays | C1 `enabled`, `active`; S1 pane Groups; C2 → `on`, `allMembersPresent` | FBD has `DisplayGroupsController`. |
| Group activation policy | Chooses when a group becomes active (always / all members / any member / any two / sync-source present) | C1 `activationPolicy`; C2 → `allMembersPresent` | |
| Group synchronisation | Syncs brightness and other image adjustments across members, with sync-source and sync-target member filters, delta syncing, and an option to include virtual screens and to sync nits | C1 `synchronization`; C2 → `off`; L is rich here | |
| UI scale matching | Matches the GUI scale across group members, with an advanced settings sheet and an enforce-on-connect option | C1 `uiScaleMatching`; C2 → `off` | FBD lists "UI-scale matching" in Appendix B but not in its own docs. |
| Layout protection | Re-applies the saved arrangement when the layout changes | C1 `layoutProtection`; C2 → `off`; S1 display Overview | FBD has `LayoutProtectionController`. |
| Configuration protection (per property) | Protects resolution, refresh rate, HDR, rotation, main status, SDR profile, HDR profile, SDR colour mode and HDR colour mode individually, plus an all-in-one | C1 `protectResolution`, `protectRefreshRate`, `protectHDR`, `protectRotation`, `protectAsMain`, `protectSDRProfile`, `protectHDRProfile`, `protectSDRColorMode`, `protectHDRColorMode`, `protectAll`; C2 probed all 10 | FBD's `ConfigProtectionController` protects mode+brightness+preset only — per-property granularity is a gap. |
| Connection management | Connects/disconnects displays, disconnects everything but the main display, reconnects all, swaps identical displays, and a per-display menu-switch behaviour | C1 `connected`, `disconnectAllButMain`, `connectAllDisplays`, `swapIdenticalDisplays`; S1 display Overview + `sheet_Additional_settings` | FBD has `DisconnectController` + `BuiltInDisconnectGuard`. |
| Built-in-disconnect guards | Refuses to disconnect the built-in panel on specific Apple hardware (M3 Macs, iMac), with an explicit override | L; ADR-referenced in FBD | FBD ships the same guard. |
| Safe mode | Holding Shift at startup avoids applying stored configuration (including EDID) | L; S1 `sheet_Load_Custom_EDID` | FBD has no safe mode. |
| Display identity / settings transfer | Chooses how a display is matched to stored settings, and transfers one display's settings onto another | S1 `sheet_Additional_settings` | |
| Forget / remember displays | Prunes remembered displays, with retention windows | L | |
| Prevent sleep while connected; prevent cursor entering; prohibit resizing; cursor warping | Small per-display layout behaviours | L | |

## E. PiP, streaming and video filters

| feature | what it does | evidence | notes |
|---|---|---|---|
| Picture-in-Picture | Shows a display (or a window, or an app's windows) in a floating window | C1 `pip`, `targetSelf`; C2 → `off`; C3 round-tripped `off`→`on`→`off` **live** | FBD has a PiP controller with display/window/app sources. |
| Multiple PiP configurations | Several PiP windows per display, added/removed by configuration id | C1 `addConfiguration`, `removeConfiguration`, `specifier`; S2 flyout "Add PIP Configuration" | FBD has one CLI PiP stream. |
| Stream display | Streams a display's contents onto another display full-screen, or to itself with filters | C1 `stream`; C2 → `off` | FBD has `stream <src> <dst>`. |
| Video filter window / content stream window | A floating window that applies filters to a chosen source, and a "selected content" streaming variant | C1 `videoFilterWindow`, `contentStreamWindow`; C2 both `off` | |
| Video filters (per output) | ~40 named filters usable on streams/PiP, with batch syntax and per-filter configuration ids | C1 `videoFilter` (full value list), `videoFilters` | |
| Window geometry and chrome | Position, size, alpha, priority (normal/topmost/absolute/absolute-lock-screen), unmovable, click-through, titlebar, shadow, magnification, origin/width/height as percentages | C1 `originX`/`originY`/`width`/`height`/`alpha`/`priority`/`unmovable`/`clickthrough`/`showTitlebar`/`showShadow`/`magnification` | |
| Geometric controls | Free aspect, integer scaling, 1:1 pixel mapping, rotate, flip H/V, zoom, underscan, cropping (origin/size), alignment guides | C1 `freeAspect`, `integerScaling`, `directPixelMapping`, `rotateBy`, `flipHorizontal`/`flipVertical`, `zoom`, `streamUnderscan`, `partial`/`partialOrigin*`/`partialWidth`/`partialHeight`, `horizontalLocation`/`verticalLocation`; S2 flyout shows the alignment-guide UI | |
| Capture behaviour | Target frame rate (0 = unlimited, 1–200), HDR rendering for filters, cursor visibility, resume-on-connect, auto-start, lock-screen visibility | C1 `fpsTarget`, `renderHDR`, `cursorShown`, `resume`, `autoStart`; L "Show on Lock Screen" | |
| Exclude PiP from capture | Keeps the PiP window out of the captured stream | C1 `excludePipWindow` | |
| Reports | DPCD report, raw DPCD dump, HDMI-CEC report, DSC report, Apple brightness report, DDC capabilities report, EDID report, display-information report | C1; C2 returned live data for all of them | Appendix B's "DSC reports" confirmed. |

## F. Automation and integration

| feature | what it does | evidence | notes |
|---|---|---|---|
| Per-display event automation | Runs a chosen action on display connect/disconnect and system sleep/wake | S1 `sheet_Configure_Events`; L ("Event integration", plus per-event descriptions) | FBD has `DisplayAutomationController` + CLI `automation`. |
| Custom control integration | Defines custom controls driven by shell commands, URLs or macOS notifications, including separate ON/OFF payloads and a script that reports the current value | S1 `sheet_Configure_Integration_Controls`; L is very detailed | |
| CLI access | Enables scripted CLI control | S1 pane Application "Integration"; L | FBD has `fbdcli`. |
| Custom URL scheme | System-wide URLs per feature, optionally token-protected, with x-callback-url result reporting | C1 documents the URL syntax + `token=`; S1 pane Application; L | FBD has `fbd://` with a token gate. |
| Built-in HTTP server | Serves the same operations over HTTP on a configurable port, optionally token-protected | C1 documents the HTTP syntax + `token=`; S1 pane Application; L names the port setting | FBD has a token-gated local HTTP API. |
| OSD notification dispatch | Broadcasts OSD events to third-party apps | C1 `osdIntegrationNotification`; S1 pane Application | |
| Shortcuts actions | A large set of macOS Shortcuts actions | S1 pane Application and pane Keyboard both link to it; L lists dozens of verb-phrased action names | FBD has `FBDIntents` with 4 actions. |
| Network / smart-device controllers | LG webOS, Samsung (Tizen), Philips (jointSPACE), Yamaha (AVR / MusicCast) — each addable as a display controller with its own sheet | S1 `sheet_Add_or_Remove_Controllers` (all four listed with add buttons); C1 `configuredControllerList`; L has per-vendor pairing and remote strings | FBD has all four (`Network/` controllers) but as CLI `tv` only, not as attachable controllers. |
| HDMI-CEC | TV control over HDMI-CEC, via DisplayPort AUX CEC tunnelling, incl. a virtual remote | C1 `sendCEC`, `CECAddress`, `CECReport`; S1 controller list + `sheet_Add_or_Remove_Controllers`; L "Show HDMI-CEC Remote" | Not in FBD. |
| DisplayLink | Indirect DDC via DisplayLink adapters, with auto-discovery | S1 controller list; L | Not in FBD. |
| Wake-on-LAN | Wakes devices over the network, incl. third-pass retry timing | L | Not in FBD. |
| Privileged helper | A helper for operations needing elevation (demonstrated by the EDID-write and configuration flows) | L | FBD deliberately avoids this; relevant to EDID writes and configuration protection. |
| Pairing / service menus | TV pairing flows, and service/hospitality menu access for smart TVs | L | Out of scope for FBD. |

## G. Menu, keyboard, OSD and app UX

| feature | what it does | evidence | notes |
|---|---|---|---|
| App menu presentation | Two presentations: a standard dropdown, or a screen-edge sidebar with glass blocks and inline expanding items | S1 pane Menu; L names both | FBD's panel is one style. The plan asks for flat **and** inline/expanding. |
| Expanding menu items / auto-tidy / collapse | Expands items inline, auto-collapses all but one device, and makes the Tools menu collapsible | S1 pane Menu; L | |
| Customise app-menu contents | Per-item visibility: always, only when expanded, or hidden | S1 pane Menu; L | |
| Slider presentation | Shows slider labels and values; enables scroll/swipe gestures on sliders; slider markers only while dragging; sub-sliders for combined brightness | S1 pane Menu; L | |
| Menu bar icon options | Icon choice (SF Symbol), centred icon, bounce animation on activity, hide when no other displays are present, per-device header icons and on/off switches in headers | S1 pane Menu; L | |
| Detachable app menu | Drags the menu off the menu bar and pins it open | S1 pane Menu (Pro-gated) | |
| Resolution-slider settings | Percentage display, magnification mode, sub-range limits | S1 pane Menu | |
| Display-mode submenu settings | Always show both LoDPI and HiDPI resolutions | S1 pane Menu | |
| Native brightness/volume keys | Lets the app handle the Apple keyboard's brightness and audio keys instead of the OS, with per-mode settings sheets | S1 pane Keyboard; L | FBD has media-key interception, off by default. |
| Keyboard-control target | Chooses which display(s) the brightness keys and the volume keys act on (mouse screen, focused screen, all suitable screens, or the display matching the current audio device) | S1 pane Keyboard | |
| Custom keyboard shortcuts | A global shortcut recorder covering a very large set of actions (brightness/contrast/gamma fine steps, rotation toggles, PiP/stream toggles, Night Shift, HDR, notch, input, main-display, and more) | S1 pane Keyboard; L lists each action name | FBD has `HotkeyController` with a much smaller set. |
| Range-based control steps | Configures the step sizes for range-based controls | S1 pane Keyboard; L | |
| Notifications and Dock | Notification style, configuration-protection notifications, Dock visibility (never / when Settings open / when a window is open), brief Dock icon on startup | S1 pane Application | |
| Warnings management | Hides/resets dismissed warnings; some warnings appear in a button bar | L; S1 `sheet_Additional_settings` | |
| Console / logging | Shows app logs in a console window | C1 `consoleLog` | FBD logs via `os.Logger`. |
| OSD style | Location, style, shadow, rounded style, adaptive background, segmented slider bar | L | |
| App UI animation speed; Tools-menu behaviour | Small UX knobs | L | |

## H. Application, updates and licensing

| feature | what it does | evidence | notes |
|---|---|---|---|
| Launch at login | Starts the app automatically | S1 pane Application | FBD has "Launch at Login". |
| Updates | Auto-check, auto-download, install, plus a pre-release channel and an internal pre-release channel | S1 pane Application; C1 `restartApp`; L | FBD has Sparkle with `UpdaterController`. |
| Pro licence | Purchase, activation, deactivation, trial countdown, licence status, "manage licence", per-install activation count | S1 pane Pro; C1 `proAvailable`; C2 → `on`; L | **Deliberately out of scope for FBD** (see the scope note): FBD has no licence server and no paid tier. |
| Pro feature gating | Marks many features as Pro in the UI and hides/disables them without a licence | L; S1 (numerous "Pro" badges); see the caveat below | |
| Crash reporting; privileged helper status | Crash reports and helper health | L | |
| About / Guide / language | Version, links, and in-app guide | S1 pane About; S1 (a Guide button on most panes) | |
| Display information export | A detailed display-information report, exportable | C1 `displayInformation`; C2 returned a full report; S1 display page `Display Information…` | |

---

## Caveats and traps encountered (read before concluding anything is "missing")

1. **A dead or dim menu row proves nothing.** In the live session, pressing the *Colour Mode* and
   *Refresh Rate* quick-menu rows did **not** open a flyout, and the *Display Mode* row behaved
   the same way — yet all three features work from Settings and from the CLI (`colourMode` state
   via `connectionMode`, `refreshRateList`, `displayModeList`). This reproduces the prior session's
   finding (HANDOFF §2.20/§2.24). Feature presence here is therefore judged from **Settings + CLI**,
   never from a menu row.
2. **`AXEnabled` is not a reliable "this row works" signal** for those rows: every app-menu row
   reported `en=1`, including ones that do not respond.
3. **Pro gating could not be observed by feature availability on this machine.** The installed
   build reports `proAvailable = on`, so Pro-marked features were reachable. The `Pro` *labels*
   are recorded, but "is this feature Pro?" is taken from the CLI reference (`C1`, which marks
   each parameter) rather than from runtime behaviour.
4. **Feature presence ≠ working on this machine.** Several features need permissions or hardware
   that this Mac lacks (no DDC-capable external display; only macOS 27). Notably: DDC hardware
   rows, HDMI-CEC, DisplayLink, Sidecar, the built-in-XDR direct paths, and the TV/AVR
   controllers were **inventoried but not exercised**.
5. **The Settings walk covers one display.** Only the built-in panel is connected, so per-display
   panes were read for that display; there is no external-display variant to compare.
6. **Some sheets were read but not fully explored.** The 12 sheets were opened, dumped and
   screenshotted, but deeper levels behind them (e.g. the controller-configuration sheets for
   each network vendor, the custom-shortcut recorder, and the menu-contents customiser) were left
   as one level of depth. Their existence and purpose are recorded; their full option sets are not.

## Coverage statement

- Every Settings sidebar pane was walked: **Displays, Groups, Application, Menu, Keyboard, Pro, About**
  (`S1`). Every sub-entry inside Displays (Overview, plus the per-display page) was walked.
- Every sheet-opening button on the display page was opened: **12 sheets** (`S1`).
- The app menu was enumerated top-level, plus one flyout live (`S2`); the remaining flyout bodies
  come from the prior session's same-build dumps (`P`).
- The CLI reference was captured in full and its parameter space probed: **271 documented
  parameters, 268 probed, 113 with live values, 5 round-tripped** (`C1`–`C3`).
- Four independent sources were used and cross-checked; `__cstring` mining was attempted and found
  redundant (mangled Swift symbols dominate) apart from the CLI help block already captured.
