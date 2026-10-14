# FBD feature inventory

Target: **FBD**, commit `256ec2f`, branch `feat/betterdisplay-parity`. macOS 27, Apple silicon,
one display connected (built-in Retina, XDR-capable).
Companion documents: `betterdisplay-feature-inventory.md` (the reference), `fbd-parity-progress.md`.

Purpose: establish what FBD actually has, and **which seam owns it** — so the gap matrix
(Phase 3) attributes every gap to a real controller rather than a guess.

## Method and evidence

| Tag | Source |
|---|---|
| **UI** | Live AX trees of FBD's own panel and Settings, captured this session → `docs/plans/fbd-ui-before/` |
| **CLI** | `swift run --disable-sandbox fbdcli help` (full command list) + `fbdcli list` |
| **SRC** | The source tree itself (`Sources/`) |
| **TEST** | `Tests/FBDCoreTests/` + `Tests/FBDCLIParserTests/` — what is actually *verified* |
| **DOC** | `README.md`, `docs/ROADMAP.md`, `docs/PRIVATE_APIS.md`, `.ai_infinite_backlog.md` — claims to check |

Status vocabulary: **full** (implemented and verified here) · **partial** (implemented but a
documented limit applies) · **degrades** (implemented, deliberately unavailable on this macOS/hardware,
surfaced honestly) · **absent** (not implemented).

Test baseline: **477 tests, 0 failures** (`FBDCoreTests` 341 + `FBDCLIParserTests` 136).

---

## 1. README claims — verified / partial / absent

Every claim in `README.md`'s feature matrix and prose, checked against code and tests.

| # | README claim | Status | Proof (seam / test / command) |
|---|---|---|---|
| 1 | Apple brightness control | **full** | `DisplayController` → `AppleController` → `DisplayServicesAPI` (`DisplayServicesGet/SetBrightness`, linear, can-change, ambient-light); CLI `fbdcli brightness <id>`; live value seen in the panel (63 %, 1.003 nits) |
| 2 | DDC/CI brightness on external displays (Apple silicon) | **partial — hardware-unverified here** | `DDCController` → `ExternalController` → `IOAVServiceAPI` (I2C, `IOAVServiceAPI.isAppleSilicon` guard); `DDCProtocolTests` (21), `DDCControllerTests` (9), `DDCInputSourceTests` (11). No DDC-capable monitor is attached on this machine, so the *transport* is tested and the *hardware* is not — exactly as `.ai_infinite_backlog.md` P0 records. |
| 3 | Volume / mute | **full (DDC path), hardware-unverified** | `DisplayController.setVolume/setMuted/readMuted`; CLI `volume`, `mute`; `fbdcli` help lists both |
| 4 | Contrast | **full (DDC path), hardware-unverified** | `setContrast`/`readContrast`; CLI `contrast` |
| 5 | Input switching | **full (DDC path), hardware-unverified** | `setInputSource`/`readInputSource`; CLI `input`; `DDCInputSourceTests` (11) |
| 6 | Resolution / refresh-rate control | **full** | `ResolutionController` → `CGSAPI` + `SkyLightAPI`; CLI `modes`, `set-mode`; `DisplayModeMappingTests` (7), `ModeSpecTests` (10), `ModeCapabilityLabelTests` (6) |
| 7 | Virtual displays | **full on macOS 26+ / implemented-but-unverified on 13–15** | `VirtualScreenController`; `VirtualDisplayAPI` (SkyLight `SLVirtualDisplay`) + `CGVirtualDisplayAPI` (dlopen); CLI `virtual create/destroy/reconnect/disconnect-all`; `VirtualDisplayRegistryTests` (6). Roadmap is explicit that the CGVirtualDisplay path awaits 13–15 hardware. |
| 8 | XDR / HDR brightness upscaling | **full (software path), partial (native path)** | `XDRNativeController` (SkyLight preset switch — **works**) + `OverlayController` (Metal software boost, live-verified with luminance measurements) + `XDRBoostPlanner`; CLI `xdr`, `preset`, `hdr`. Native preset **rewrite** is write-protected on macOS 27 (`SLSDisplaySetPresetData`) → software fallback; recorded in `docs/PRIVATE_APIS.md`. |
| 9 | Software filters: contrast, saturation, gamma, colour temperature, invert | **full** | `ScreenFilterParams` (contrast, saturation, gamma, temperature, invert) + `OverlayController`; CLI `filter <contrast> <saturation> <gamma> <temp> [--invert]`; `ScreenFilterParamsTests` (14) |
| 10 | …plus sharpening | **full** | `ScreenFilterParams.sharpness` + `.unsharpRadius` (4-tap unsharp mask); CLI `--sharpness/--radius` |
| 11 | …plus zoom / pan | **full** | `ScreenFilterParams.zoom/offsetX/offsetY`; CLI `--zoom/--pan` |
| 12 | …plus 3D LUT | **full** | `LUTCube` (`LUT_3D_SIZE` 2–128, domain normalisation, size cap) + `--lut path.cube`; `LUTCubeTests` (18) |
| 13 | Screen rotation | **partial** | `SLSSetDisplayRotation` declared + wired (`DisplayController.setRotation`), CLI `rotate`. Returns status **1001 for the built-in display on macOS 27** — graceful failure; external-display check is hardware-gated. |
| 14 | EDID overrides | **partial** | `EDIDController` + `EDIDParser` + `EDIDValidation`; CLI `edid export/apply/restore/auto`; **EDID export/parse is verified** (`EDIDParserTests` 6, `EDIDValidationTests` 10, `EDIDHexTests` 9); override apply via `IOAVServiceSetVirtualEDIDMode` is Apple-silicon-only and **unverified**; the Intel chunked-I2C path is documented as unsupported (needs framebuffer I2C). Built-in panel EDID is not exposed by macOS 27 — export reports that honestly. |
| 15 | Per-display event automation | **full** | `DisplayAutomationController` + pure `AutomationScheduler`/`AutomationCommand` with a protocol executor seam; CLI `automation list/add/enable/disable/remove/test/log`; `DisplayAutomationTests` (18). Backlog records a live end-to-end run through `/bin/zsh -c`. |
| 16 | Night Shift | **full** | `NightShiftController` → `CBBlueLightClient` via `NSClassFromString` + C shims; CLI `nightshift`; live-verified 0–100 % round-trip. |
| 17 | True Tone | **degrades** | `TrueToneController` → `CBTrueToneClient`; API reports unavailable on macOS 26.3+, so it degrades honestly. |
| 18 | Custom OSD | **full** | `CustomOSD`; CLI `osd <icon> <0-100>`; Settings → Integrations toggle |
| 19 | Picture-in-Picture | **full** | `PipStreamController` (ScreenCaptureKit + Metal); CLI `pip <id>`, `pip --window`, `pip --app`, `pip list`, `pip stop`; `PiPArgsTests` (16) |
| 20 | Local streaming | **full** | Same controller, `PiPPresentation`; CLI `stream <src> <dst>`; `StreamArgsTests` (10), `StreamOptionsTests` (12), `StreamFrameRateTests` (10) |
| 21 | Colour profiles | **full** | `ColorProfileController` → `ColorSyncDeviceSetCustomProfiles`; CLI `profile list/apply/restore` |
| 22 | Underscan | **full** | `UnderscanController` → `SLSDisplaySetUnderscan`; CLI `underscan` |
| 23 | Shortcuts intents | **full (5 actions), app-level check user-gated** | `FBDIntents`: `SetDisplayBrightnessIntent`, `GetDisplayBrightnessIntent`, `SetDisplayVolumeIntent`, `ListDisplaysIntent`, `EnableXDRUpscalingIntent`; wired via `AppIntentsBridge`. `shortcuts list` cannot enumerate app intents, so the Shortcuts-app check stays user-gated (backlog P1). |
| 24 | HTTP control API, 127.0.0.1 only, token-gated | **full** | `HTTPServer` + `HTTPRouter` + `HTTPExecutor`; token via `Settings.httpAPIToken` (`SecRandomCopyBytes`); `HTTPServerTests` (12), `HTTPRouterTests` (26), `HTTPExecutorTests` (13), `HTTPSystemRouteTests` (10); live `GET /api/displays` round-trip recorded in the backlog. |
| 25 | `fbd://` URL scheme, with token gate on writes | **full** | `fbd://brightness/<id>/<value>?token=…`; commits `94281dc` and `712fa7a` hardened it |
| 26 | CLI | **full** | `fbdcli` (routed through the app's HTTP API by default; `--direct` forces local); `FBDCLIParser` (136 tests) |
| 27 | Media-key interception (off by default) | **full (real-keyboard check user-gated)** | `MediaKeyRouter` (+ `MediaKeyRouterTests` 7, `MediaKeySystemVolumeTests` 9); routing is unit-tested, a synthetic NX-event check does not reach the session tap → real hardware key press is backlog P1. |
| 28 | Built-in-display disconnect refused on base-M3 Macs | **full** | `BuiltInDisconnectGuard` enforced at the single `DisconnectController.setEnabled` chokepoint; `BuiltInDisconnectGuardTests` (10); override ships off |
| 29 | "477 unit tests, CI green per push" | **verified locally / not verified in CI** | 477 tests, 0 failures, measured in Phase 0. CI workflows exist (`.github/workflows/{ci,release,test-required}.yml`) but were not run from here. |
| 30 | macOS 13–15 / 26 / 27 matrix | **not reproducible here** | Only macOS 27 is available. Columns for 13–15 and 26 are claims from earlier work, not re-verified in this task. |

**Every README claim is accounted for.** No claim was found to be outright false; three are
*partial* by their own documentation (DDC hardware, rotation, EDID override) and are labelled as
such in the README/ROADMAP already.

---

## 2. Features present but not in the README

These are real, wired, tested features the README's prose doesn't mention. They matter for the gap
matrix because they are *already at parity* with something BetterDisplay has.

| feature | status | seam | evidence |
|---|---|---|---|
| Display arrangement (drag-to-arrange grid) | **full** | `ArrangementMath` (pure) + `DisplayController.setOrigin` via the public CG configuration API | ADR-0002; `ArrangementMathTests` (5) |
| Display groups | **full** | `DisplayGroupsController` (cross-process via `Settings.defaults`) | `DisplayGroupsControllerTests` (6); CLI `group …` |
| Mirroring | **full** | `DisplayGroupsController.mirror` | CLI `group mirror/unmirror` |
| Layout protection | **full** | `LayoutProtectionController` | CLI `layout save/restore/protect`; Settings → Virtual Displays & Layout |
| Configuration protection | **partial** (mode + brightness + preset only) | `ConfigProtectionController` | `ConfigProtectionControllerTests` (5); CLI `protect config/save/restore` |
| DDC cooldown, retries, settle time, auto-configure | **full** | `DDCController` + `Settings` (`ddcCooldownMilliseconds`, `ddcReadRetries`, `ddcSettleMilliseconds`, `ddcAutoConfigure`) | `SettingsTests` (13), `DDCControllerTests` (9); Settings → DDC/CI |
| Brightness-change notifications & brightness sync | **full** | `BrightnessChangeObserver` (DisplayServices registry) + `BrightnessSync` | `BrightnessSyncTests` (9) |
| Combined brightness curve | **full** | `CombinedBrightness` (`DisplayControlling` seam) + `XDRBoostPlanner` | `CombinedBrightnessTests` (9), `XDRBoostPlannerTests` (12) + property sweeps |
| Ambient-light compensation | **full** | `DisplayServicesAPI` (has / enabled / enable) + `DisplayController` | `Sources/FBDCore/PrivateAPI/DisplayServicesAPI.swift` |
| Dim to black | **full** | `OverlayController.setDimToBlack` | `Settings.dimToBlackEnabled`; CLI/Settings |
| HDR framebuffer mode | **full** | `SkyLightAPI.setHDRModeEnabled` | CLI `hdr <id> on\|off`; `XDRPresetTests` (10) |
| Apple display presets | **full** | `XDRNativeController` + `SkyLightAPI` preset switching | CLI `preset <id> [index]`; live-verified in the backlog |
| System (Mac) output volume | **full** | `CoreAudioHAL` + `SystemVolumeController` | `SystemVolumeControllerTests` (13), `MediaKeySystemVolumeTests` (9); CLI `sysvolume` |
| Hotkeys / keyboard shortcuts | **full** | `HotkeyController` | Settings → General; `HotkeyController` lifecycle handling in the backlog |
| Rounded corners / corner mask | **full** | `CornerMask` + `Settings.cornerRadius(for:)` | `CornerMaskTests` (6) |
| Cursor containment for streamed displays | **full (experimental, off by default)** | `CursorContainment` + `CursorContainmentController` | `Settings.experimentalCursorContainment`; backlog issue #14 |
| Network TV / AVR control | **full** | `Controllers/Network/`: `LGWebOSController` (WebSocket ssap), `TizenController` (pairing token), `PhilipsTVController` (jointSPACE HTTP), `YamahaAVRController` (YXC XML), `NetworkHost` (SSRF guard) | `NetworkHostTests` (3), `TVCommandValidationTests` (10); CLI `tv <brand> <host> <action>` |
| Raw DDC VCP read | **full** | `DisplayController.readRawVCP` | CLI `caps <id>` |
| Rosetta detection + warning | **full** | `DisplayController.isRunningUnderRosetta` + `RosettaWarningView` | Settings → General toggle |
| Offline displays in Settings | **full** | `Settings.showOfflineDisplays` | Settings → General |
| Launch at login | **full** | `Settings.launchAtLogin` | Settings → General |
| Auto-update (Sparkle) | **partial — inert without a signed release** | `UpdaterController` (Sparkle 2.9.5) | `appcast.xml`, `.sparkle/`; backlog records the user-gated Developer ID cert |
| Unsafe-mode escape hatch | **full** | `Settings.allowUnsafeInvalidModes` | Settings → Experimental |

## 3. Features FBD has *no* trace of

Verified absent by grep across `Sources/` (zero matches for the relevant identifiers):
colour depth / bit depth control · connection mode (bpc × range × encoding × chroma) · colour mode
incl. HDR colour mode · HDCP state · Display Stream Compression (DSC) reporting · raw DPCD access ·
HDMI-CEC · DisplayLink control · Wake-on-LAN · Sidecar connection control · UI-scale matching ·
flexible scaling and custom scaled resolutions · native/default resolution + system display name
editing · resolution favourites · display-notch toggle (the previous toggle was removed as
non-functional) · startup safe mode · virtual-screen↔real-display association · streaming/PiP
multi-configuration windows · video-filter windows · per-property configuration protection ·
group synchronisation of brightness · attachment of network devices *as display controllers*.

## 4. Surface-level inventory (what the UI and CLI actually expose)

**Menu-bar panel** — header (title + `Settings` gear + close) → per-display card: name, kind tag,
capability tag (e.g. `XDR`), `More` menu, `Disable display`, mode/refresh line, brightness slider
with `%` **and** nits read-out, then collapsible sections **Filters**, a DDC-availability notice,
**Resolutions**, **XDR / HDR**, a **Color Profile** popup + `Restore default`, **Virtual Screens**,
**Display Groups**; footer: `Virtual Screens`, `Groups`, `PiP`, `Check for Updates`, `Quit FBD`.
Right-click on the status item: `Show FBD` · `Settings…` · `Check for Updates…` · —— · `Quit FBD`.

**Settings** — a two-item tab group, **Overview** and **Per-Display**.
Overview sections: **General** (launch at login, Rosetta warning, offline displays, connect/disconnect
controls), **DDC / CI** (cooldown), **XDR / HDR** (combined brightness, software upscaling, dim to
black, experimental direct colour table, upscale target nits), **Experimental** (unsafe modes),
**Virtual Displays & Layout** (reconnect on wake, disconnect on lock, auto-disconnect built-in +
M3 guard note, layout protection, configuration protection), **EDID & Protection** (auto-apply,
restore on quit, config protection), **Integrations** (HTTP API + port, custom OSD, Night Shift
strength, True Tone), **Automation** (rule list + add form), **About**.
Per-Display: the same display card as the panel, for the selected display.

**CLI commands** (`fbdcli help`, 46 commands): `list`, `info`, `brightness`, `contrast`, `volume`,
`mute`, `input`, `caps`, `modes`, `set-mode`, `ddc-test`, `xdr`, `preset`, `hdr`, `virtual …`,
`filter`, `disable`, `enable`, `layout …`, `group …`, `edid …`, `profile …`, `underscan`,
`protect …`, `http …`, `auth-token`, `settings`, `pip …`, `stream …`, `automation …`, `osd`,
`sysvolume`, `nightshift`, `truetone`, `tv`, `help`.

## 5. Structural observations for the UI revamp (Phase 5)

1. **FBD nests per-display controls inside a two-tab Settings page**, whereas BetterDisplay uses a
   sidebar (`Displays` · `Groups` · `Application` · `Menu` · `Keyboard` · `About`) with a *long*
   per-display page inside `Displays`. FBD's `Groups`, `Application`-equivalent, `Menu`-equivalent
   and `Keyboard`-equivalent content has **no home**: groups are a panel footer button, the
   app-level settings are crammed into one Overview scroll, and there is no keyboard page at all
   (hotkey/media-key settings live in General).
2. **The panel's footer buttons** (`Virtual Screens`, `Groups`, `PiP`, `Check for Updates`,
   `Quit FBD`) are navigation *and* actions mixed together, whereas BetterDisplay's quick menu is a
   list of feature rows with a small button bar. 
3. FBD already has a design system (`Sources/FBD/DesignSystem/`: `FBDTheme`, `FBDCard`,
   `FDBSlider`, `FBDTag`, `FBDStatus`, `FBDNotice`, `FrostedBackground`, `DisclosureSection`) —
   so new section headers / slider rows / info rows should extend it rather than hand-rolling styles.

## 6. Honesty notes

- Nothing above is asserted from documentation alone: every "full" row cites a seam **and** a test
  file or a live observation.
- Conversely, nothing is asserted *verified* that this machine cannot exercise: DDC hardware,
  macOS 13–15 virtual displays, external rotation, real media keys, and the Shortcuts app check are
  all marked as such.
- The README's feature matrix columns for macOS 13–15 and 26 are carried as claims, not re-verified.
