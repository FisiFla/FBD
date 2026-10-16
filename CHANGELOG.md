# Changelog

All notable changes to FBD. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: semver from 1.0.0 (the first release with an update feed).

## [Unreleased]

## [1.8.1] - 2026-10-16

### Fixed
- External displays on Apple Silicon were never matched to their AV service, so DDC/CI and
  EDID reads could not work on any monitor. The service is now paired by EDID UUID and
  registry order (verified on hardware: the EDID reads back over I2C).
- `IOAVServiceCreateWithService` and `IOAVServiceCopyEDID` were declared with the wrong
  signatures (missing allocator; missing out-parameter).
- A display that has an AV service but never answers DDC/CI (most TVs) is no longer offered
  DDC controls after its first refresh.
- `fbdcli config group-sync` exited before its debounced brightness writes landed, so it reported success without changing anything.
- `fbdcli ddc-test` now reports the AV service and the DDC/CI reply separately.

### Changed
- Scaled modes the system reports without the HiDPI flag (seen on an LG TV, "looks like
  1920x1080" on a 4K backing) are now treated as HiDPI. The CLI labels non-HiDPI modes
  `lodpi` instead of `sdr`, which is an HDR term.
- EDID overrides are disabled on Apple Silicon. `IOAVServiceSetVirtualEDIDMode` was declared
  with the wrong arguments (disassembly shows a 32-bit mode plus raw EDID bytes), and its mode
  values are undocumented, so applying an override now fails instead of guessing.

## [1.8.0] - 2026-10-16

### Changed
- **Redesigned the menu-bar panel (Control Center style, Liquid Glass on macOS 26+); Settings now
  opens in its own window.** The panel is a borderless popover sized to its content (340 pt wide,
  at most 85% of the screen tall, then it scrolls). The front page has each display's brightness
  (and DDC volume) slider, quick toggles for Dark Mode, Night Shift, True Tone and Keep Awake,
  presets, and rows for virtual screens and display groups. Every other per-display control the old
  panel had is on that display's page, one click away — resolution, refresh rate, XDR / HDR, colour
  profile, EDID, filters, monitor controls and display actions, plus what the old ⋯ menu held: HiDPI,
  Auto Brightness, resolution favourites, presets (apply and save), mirroring, Picture in Picture,
  streaming and Show in Settings — with `All Modes` as the only second level. The Virtual Screens
  page keeps `Reconnect All`. Selections are
  flat checkmark lists, and every label is plain language, localised in English, Simplified and
  Traditional Chinese. On macOS 26+ the backdrop, toggles, page header, small buttons and slider
  thumb use Liquid Glass, and the HUD defaults to glass (a saved choice wins). Earlier macOS
  versions, or `FBD_DISABLE_GLASS=1`, get the same UI with materials. CI and release builds now
  require Xcode 26+.

### Added
- **Named display presets: a display's whole configuration saved under a name, with an icon.**
  FBD could recall a resolution (`config favourite`) and restore a set of protected properties on
  reconnect, but it could not name and re-apply a display's *whole* configuration — which is what
  BetterDisplay's presets and the Crisp review's feature list both call for. A preset records the
  state `ConfigProtectionController` already knew how to capture — mode, refresh rate, brightness,
  the XDR preset, HDR mode, rotation and the colour profile — under a name the user chooses and one
  of a closed set of twelve SF Symbols, closed for the reason the menu-bar icon's set is: a symbol
  name that fails to resolve would draw a blank row. Three surfaces, plus Shortcuts:
  `fbdcli config preset <id> list|save|apply|delete`, a per-display **Display presets** section in
  Settings → Displays (icon, name, the properties it carries, apply and delete), a quick apply menu
  in the panel, and an `Apply Display Preset` App Intent. The store reuses the resolution-favourite
  shape — one JSON array per display under `displayPresets.<identity>`, the key dropped when the
  last preset goes — refuses a name already in use on that display, and applies through the same
  path reconnect-restore uses.

  Two choices are deliberate. A preset **does not** carry main-display status by default: applying
  one must not silently move the menu bar out from under another display, so `mainStatus` is
  restored only when it is asked for explicitly. And apply **reports** what it could not restore: a
  preset can name properties a display cannot accept (brightness on a panel with no brightness path,
  the XDR preset on a display that is not XDR-capable), and counting those as applied would be a
  lie — `fbdcli` prints a `skipped:` line, the panel says so in its notice, and Settings names them
  in the row.

  The extraction that made it possible is `DisplayStateSnapshot`: the private `SavedState` struct
  `ConfigProtectionController` wrote and read, made public. The stored blob is **byte-identical**, so
  a configuration saved by an older FBD still restores.
- **The pointer can cross between displays whose edges do not line up.** macOS stops the pointer at an
  edge no other display covers, so a short display beside a tall one — or one lowered out of line —
  traps it in the gap between them. `Settings.edgeCrossingEnabled` (Settings → Displays, or
  `fbdcli layout edge-crossing [on|off]`) carries it over instead: FBD watches pointer movement and,
  when a push reaches an edge a neighbour's facing edge continues, lands the pointer just inside that
  neighbour at the height it was pushed at.

  Three things were measured rather than assumed, and each changed the design. **The pointer cannot be
  polled for its direction:** macOS clamps it to the displays' bounds, so a pointer pinned at an edge
  reports *zero* movement between samples — the push has to come from the event's own hardware delta
  (`CGGetLastMouseDelta` is gone from the Swift SDK). **Warping needs no permission, and neither does
  a mouse-moved monitor** — only *key* events need Accessibility, which is the trade
  `CursorContainmentController` refuses for an event tap and this feature does not have to make. And
  **a warp holds hardware input back for a quarter of a second** by default, which reads as the pointer
  sticking, so the suppression interval is zeroed before each warp.

  It fails closed. A neighbouring display that does not actually meet the edge means nothing happens —
  a deliberate gap is respected, and the geometry refuses to move a pointer macOS would have crossed by
  itself. It is inert with one display, and if the monitor never fires it simply does nothing: it can
  never fight the user for the pointer. Off by default, like everything else in FBD that moves it.

### Fixed
- **DDC/CI now uses the framing Apple Silicon monitors expect** (5-argument `IOAVService` I2C calls,
  `0x84 0x03` / `0x82 0x01` packets, XOR checksum), matching the reference implementation. Brightness,
  contrast, volume, input and mute over DDC are rewritten accordingly; not yet verified on hardware (#7).
- Mute media key no longer only unmutes; DDC slider drags send the latest value instead of queueing
  every step; the DDC service cache is refreshed on display changes; EDID product code and serial
  are read little-endian.
- XDR upscaling above the hardware ceiling falls back to the software boost when the native preset
  write is refused (macOS 27); ending a boost no longer removes the dim or rounded-corner overlays.
- A built-in display disabled by FBD, and a lock-dimmed brightness, are restored after a crash or quit.
- `fbdcli`: a bad token or timeout is an error instead of silently driving the hardware directly;
  `--direct` inside automation payloads is preserved; `help` lists `enable` on its own line; zsh
  completion covers every command.
- **Creating a virtual screen no longer crashes FBD.** The SkyLight calls that build a virtual
  display were handed pointers to a bridged `NSString` (the name) and `NSArray` (the optional modes)
  that were temporaries: Swift released them as soon as the pointer was taken, while SkyLight kept
  using it, so creating a screen from the app crashed. Both objects are now kept alive for the whole
  call.

### Security
- The HTTP API token and LG TV pairing key moved from preferences to the Keychain (migrated on first
  run). `fbdcli` may show a one-time Keychain prompt.
- The local API rejects browser requests (non-loopback `Host` or any `Origin`), sends no CORS headers,
  caps concurrent connections and no longer falls back to a guessable token.
- `FBD_DISPLAY_NAME` (from the monitor's EDID) is sanitised before it reaches automation scripts.

## [1.7.0] - 2026-10-14

BetterDisplay-parity work agreed at the Phase 3 gate. Scope, evidence and the
deliberate exclusions are in `docs/plans/betterdisplay-parity-scope.md`,
`docs/plans/fbd-gap-matrix.md` and `docs/plans/fbd-parity-progress.md`.

### Added
- **A live DPCD read over AUX: `fbdcli dpcd <display>`.** Row 24's read path — `IODPDeviceReadDPCD`,
  the AUX route to a DisplayPort sink's registers where DSC, link training and tiling are described —
  reached through a runtime-resolved IOKit shim that declares **only** the read. Its write-side
  neighbours (`IODPDeviceWriteDPCD`, the retrain and set calls) resolve on this macOS and are
  deliberately not declared: a wrong write there can wedge the only attached display. The command
  reads a block and hands it to the decoder `report --dpcd` already uses, and a failure reports *which*
  step declined rather than one message for three causes. Verified as far as this machine allows: the
  entry points resolve, the argument validation and the decode path are exercised, and against the
  built-in panel it declines at service discovery, because FBD's registry walk is tuned for external
  displays. **Proving a read end-to-end needs an external DisplayPort display**, which this Mac has
  none of. A guessed fallback for the built-in panel was written, measured, and removed rather than
  shipped unverified.
- **The HUD can use the system's glass.** FBD's HUD is a vibrancy view in `.withinWindow` mode,
  which samples the *window's own* content — the SwiftUI content and nothing else — so it draws a
  flat panel rather than sampling the desktop behind it. The OS's glass (`NSGlassEffectView`,
  macOS 26+) is now a third HUD background; the default is untouched, so an untouched install keeps
  the look it has always had. Captured on macOS 27: it renders correctly, and the difference is
  subtle — which matches the Crisp review's own note that no glass material can hold a HUD's
  backdrop on this OS family. Two measured facts shaped it: only `contentView` is guaranteed to sit
  inside the glass (so the SwiftUI content goes there, not in as a subview), and `.behindWindow` is
  *not* a substitute for `.withinWindow` here.
- **FBD speaks 简体中文 and 繁體中文 — starting with the panel.** Crisp ships en · 简体中文 · 繁體中文
  and FBD shipped English only. The mechanism is deliberately the small one: three
  `.lproj/Localizable.strings` beside the icon in `Sources/FBD/Resources`, copied into the bundle by
  `make app`, which is where macOS looks for them — no SwiftPM resource bundle, and **no code
  change**, because SwiftUI already resolves `Text("Display Mode")` against the app bundle. The
  225 strings now cover the panel, the Settings pages and the filters/automation views. That last
  round turned up the real defect rather than a missing translation: `SettingsRow`,
  `SettingsSliderRow` and `disclosureSection` took `title: String`, and `Text(String)` is *verbatim*
  — SwiftUI only looks a key up through a `LocalizedStringKey` — so every settings title and every
  section header, the panel's included, was invisible to these files no matter how many translations
  were added. All call sites pass literals, so the parameters became `LocalizedStringKey` and the
  titles started resolving: verified live in the app's accessibility tree, where "Connect all" now
  reads 全部连接. A test stops the three files drifting: the languages must agree on every key, and
  every key must still appear in the source, since a renamed string would otherwise silently stop
  resolving and look like "not translated yet" rather than broken. The Settings sidebar went the same
  way: it rendered `Text(item.rawValue)`, a String, so its labels were verbatim too, and `SettingsPage`
  now spells its cases out in a `switch` returning `LocalizedStringKey` — which keeps every key a
  literal the test can verify (236 keys each). What the drift test cannot reach is an *interpolated*
  string: SwiftUI turns `Text("\(nits) nits")` into the format key `%lld nits`, which never appears
  verbatim in the source, so the "every key still exists" check would reject an entry for it. That is
  now fixed rather than accepted: the check understands format keys and verifies their literal
  segments, so the interpolated strings are localised too — `%lld nits`, `%lld Hz`, `%lld display%@`
  and `%lldpx`, 240 keys per language. The Chinese forms drop the English plural, which is why a
  translation may omit a placeholder. What remains English is numbers with no words in them, and the
  automation model's own `label`/`token` — those stay English on purpose, because `FBD_EVENT_LABEL`
  hands them to shell rules as a script contract, so the UI maps those cases itself. Two things worth
  recording — `Sources/FBD/Resources` is `exclude`d from the SwiftPM target (which is why Info.plist
  lives there and is copied by hand), so the `.lproj` directories have to be copied by the Makefile;
  and `CFBundleLocalizations` must **not** sit alongside real `.lproj` directories, because it made
  macOS report every language twice, a signal that sends the next person hunting a nested copy that
  is not there.
- **The DDC input menu marks the input in effect.** It marked nothing until now: reading VCP 0x60 was
  a blocking DDC read, so the panel deliberately refused to guess and its title said "Choose…". The
  read now rides in the *same* batched read as contrast/volume/mute — one more feature on the
  display's own queue, off the main actor — so the menu shows a checkmark on the current input, its
  title names it, and where a monitor refuses to answer it falls back to the last input set rather
  than claiming knowledge it does not have. The `Double → UInt16` conversion is a tested helper
  (`DDC.inputSource(from:)`) rather than an inline cast in a view, where an out-of-range answer would
  have trapped.
- **A Dark Mode toggle, completing Night Shift + True Tone.** Crisp has all three system toggles and
  FBD had two. The mechanism is Crisp's: SkyLight's appearance theme
  (`SLSGetAppearanceThemeLegacy` / `SLSSetAppearanceThemeLegacy` / `SLSSetAppearanceThemeNotifying`),
  resolved at runtime through a C shim like every other private surface, so a Mac without those
  symbols degrades to "unavailable" rather than crashing — and the notifying variant is preferred so
  the switch crossfades the way Control Center's does. Available as `fbdcli dark-mode [on|off]`
  (bare, it reports) and as a toggle beside True Tone in Settings. Deliberately **not** stored in
  `Settings`: it is the system's switch and another app can flip it, so the UI reads it live rather
  than remembering a value that could go stale.
- **The resolution list shows the sizes you actually switch between.** The panel's Resolutions
  section offered every mode inline — 132 of them on this machine — while reaching one through
  the ⋯ submenu cost three clicks, so neither route was good. It now shows one row per logical
  size at the current mode's aspect ratio, HiDPI preferred, with the mode in effect always on
  the list, and **Show all N modes** one click away. `CuratedModes` is pure, so what counts as
  worth showing is unit-tested: one row per size, the current mode owns its own row, variants
  win elsewhere, other aspect ratios wait behind "show all", and truncation never drops the
  mode that is on screen.
- **Configuration protection covers rotation and the colour profile.**
  `ProtectedProperties` offered six of BetterDisplay's nine properties; it offers eight now.
  Neither new one can be *read* — there is no readable rotation and no readable current
  colour profile — so both are restored from the value FBD itself last applied, recorded as
  it applies it; one set by another tool is invisible, which the type says plainly. The
  legacy default is deliberately unchanged, so upgrading never begins re-applying more state
  than before: widening remains an explicit choice.
- **A saved network device can be attached to a display.** The device then follows that
  display's volume when the brightness/volume keys drive it, so a TV or AVR stops being
  something reachable only through `fbdcli tv`. Attachments are keyed by the display's
  **identity**, not its id, so a reconnect keeps them; `fbdcli config device
  attach|detach|attachments` manages them, and a device deleted afterwards is reported as
  dangling rather than silently resolving to nothing. Philips sets are the one exception,
  and say so: pairing needs a PIN read off the TV and that pairing does not outlive the
  controller instance, so a fire-and-forget volume send cannot complete it.
- **Manual controls and a notification action for automation.** A rule can be scoped to
  `manual` — a control you invoke yourself, via the new Run button in Settings →
  Automation or `fbdcli automation run` — and a `notify` action posts a user
  notification, which runs in-process rather than through a shell. ON and OFF are two
  manual rules, and a shell control that prints its state already records that output in
  the run log, which is how a state-query control is built. Notification permission is
  asked for only once a notification rule exists, never at first launch, and
  `fbdcli automation run` refuses a notification rule outright — the CLI is a bare binary
  with no bundle identity or authorisation, so a request from there would be accepted and
  then dropped, and reporting success would be a lie.
- **`fbdcli report [file]` — an exportable display report.** A detailed, paste-ready block
  per display (identity, kind, geometry, current mode with its colour encoding, mode count
  and refresh rates, control paths, brightness, XDR/HDR state) under a header carrying the
  FBD and macOS versions — the macOS version because display behaviour differs per release.
  Prints, or writes to a file for attaching to a bug report. The formatting lives in
  `DisplayReport` in FBDCore and is locked by format tests, so it cannot drift silently.
- **The HTTP API covers four more of the parity settings.** `POST
  /api/config/connections` runs the connection planner through the same guarded
  disconnect chokepoint the Settings buttons use; `POST /api/config/protection` sets a
  display's protected-property selection (the display may be a number or the string
  `/api/displays` returned); `POST /api/config/device` lists, adds or removes a saved
  TV/AVR; and `POST /api/config/favourite` lists resolution favourites, records the
  current mode into a slot, or recalls one. Each validates its input and names the valid
  values when it refuses, and a favourite whose mode is gone is reported rather than
  approximated.
- **Three Shortcuts actions for the parity surfaces.** `Set Lock Dim`, `Set Keyboard
  Control Target` and `Sync Display Group` join the existing display actions, so the
  new features are scriptable from Shortcuts as well as from `fbdcli` and the app.
  `Sync Display Group` runs the same tested planner as the Settings page's "Sync now",
  and each action validates its input and names the valid values when it refuses.
- **The HTTP API covers the parity settings.** `GET /api/config` reports the new
  settings — lock dim, the keyboard control target (with the valid values), the
  brightness model and configuration protection; `POST /api/config/lockdim` and
  `POST /api/config/keytarget` set them. Both writes take effect without a restart,
  because each is read back at use time: lock dim re-reads its policy on every lock
  event, and the media-key path reads the control target on every press. Both go
  through `Settings`, the same single write path the app and `fbdcli` share. The
  existing token gate and method gate apply unchanged, and an omitted
  `targetPercent` keeps the stored level rather than resetting it.
- **A saved network-device registry.** FBD already had working LG webOS, Samsung,
  Philips and Yamaha controllers, but reaching one meant repeating the brand and
  host on every single command and nothing remembered a device between runs.
  `NetworkDeviceRegistry` stores them (name, brand, host, optional Yamaha zone)
  through the single settings write path; `fbdcli config device list|add|remove`
  manages them; and `fbdcli tv <name> …` addresses one by name. A host that could
  redirect the request — a scheme, path, credentials, query, or a `:port` suffix
  — is refused when the device is added rather than stored for later.
- **`fbdcli config` completed**: `group-sync <group> <0-100>`,
  `connections connect-all|disconnect-all-but-main|swap-identical`, and
  `model <key> [value]` — the last of which also makes each brightness-model
  value settable on its own instead of only as one opaque blob.
- **Per-property configuration protection.** Protection was one opaque blob
  (mode + brightness + preset). It now protects six properties independently —
  resolution, refresh rate, preset, HDR mode, main status and brightness — each
  selectable per display (`ProtectedProperties`, the Displays page, or
  `fbdcli config protect <id> <properties>`). The default stays the old set, so
  an existing install behaves exactly as before until the user widens it, and a
  property the display cannot report is never forced.
- **Display-group synchronisation and activation policy.** Groups gained an
  enable flag, one of five activation policies, sync source/target member
  filters, an optional nits-matching mode, and a pure `GroupSyncPlanner` that
  reuses `BrightnessSync` for the nits maths. Managed on the new Groups page and
  via `fbdcli config group-policy|group-enabled`.
- **Resolution favourites.** Five recall slots per display, recorded and applied
  from the Displays page or `fbdcli config favourite <id> save|apply|list`. A
  slot is recalled exactly, then by an equivalent mode, otherwise it reports
  itself unavailable rather than applying a wrong mode.
- **Mode-list breadth and a refresh-rate list.** `ModeFilterOptions` plus a
  deduplicated descending `refreshRates(from:)`. The unexposed (NTSC) timings
  BetterDisplay lists are *not* faked: `docs/PRIVATE_APIS.md` records that the
  private queries behind them need a live WindowServer connection and crash a
  process without one, so the gap is documented.
- **A tunable brightness model.** `BrightnessPreferences` exposes the combined
  curve: hardware min/max nits, HDR peak SDR/HDR nits, a re-defined 0 % software
  level, a minimum hardware level, the software-dimming switchover point, the
  upscaling maximum, whether hardware control is preferred, and what to assume
  about stored control values at startup. `BrightnessCurve` is the pure
  mapping; every field is clamped, inverted bounds are repaired, and a
  non-finite value falls back to its default rather than to the ceiling.
- **Startup safe mode.** Holding ⇧ Shift at launch — or `FBD_SAFE_MODE=1` —
  skips stored EDID overrides and configuration-protection restore for the
  session. Fail-closed: it only ever suppresses an apply, and says so.
- **Lock dim.** Dims to a chosen level while the screen is locked or the
  screensaver is up, and restores the recorded brightness on unlock. The state
  machine never dims blind, is idempotent on a repeated lock, and always has a
  restore path.
- **Keyboard control target.** The brightness and volume keys can act on the
  screen under the pointer, the focused screen, every suitable screen, or the
  display whose name matches the current audio device (exact or partial match),
  with a deterministic fallback so a key press is never silently swallowed.
- **Connection management.** `ConnectionPlanner` produces ordered
  connect/disconnect/swap steps, executed through the existing guarded
  `DisconnectController` chokepoint. It never emits a built-in-display disable
  unless the explicit override is set, and refuses outright when there is no
  main display.
- **`fbdcli config`** — one command for the settings above (`show`, `protect`,
  `favourite`, `lockdim`, `lockdim-target`, `keytarget`, `group-policy`,
  `group-enabled`), running locally against the shared defaults with no second
  write path. Unknown property names, targets and on/off words are refused
  rather than silently ignored.
- **A sidebar Settings layout.** Settings was a two-tab form; it is now a
  sidebar of `Displays` · `Groups` · `Application` · `Menu` · `Keyboard` ·
  `About` with long pages, and the panel grows to 760×860 for it.
- **Keyboard shortcuts on the panel's own controls.** The settings gear takes ⌘,
  and the tools footer ⌘⇧V (Virtual Screens), ⌘⇧G (Groups), ⌘⇧P (PiP), ⌘U
  (Check for Updates) and ⌘Q (Quit FBD). The panel's controls previously carried
  no key equivalents at all — ⌘, only duplicated the one the status menu already
  had. This works because the panel can take key focus: its style mask carries
  both `.titled` and `.nonactivatingPanel`.
- **`fbdcli ambient-light <display> [on|off]`.** Reads or sets the Apple panel's
  ambient-light auto-brightness. The seam existed and was reachable from the
  panel's More menu but had no CLI surface (gap-matrix row #12). A bare read
  doubles as the capability probe — a display with no ambient-light sensor is
  reported unavailable and exits 2 — and a set is confirmed by reading the state
  back rather than trusting a status code.
- **The status item's icon is now a choice, and it can hide itself when there is
  nothing to control.** Settings → Menu → Status item offers a curated set of SF
  Symbols (each measured to resolve on macOS 27 — the list is closed rather than
  free text, because a name that fails to resolve would leave a menu-bar app with
  no button), and an option to hide the icon while no display other than the
  built-in one is attached. That option is refused unless a Dock icon is enabled:
  hiding the item with no other way in would strand the user, so the policy fails
  closed instead. Choosing an icon that cannot be resolved falls back to the
  default rather than leaving the button blank.
- **`fbdcli config identity` and `config transfer`.** Which key a display's
  stored settings are filed under is now a choice — vendor+model+serial (the
  default), vendor+model, serial alone, or the display's name — and one display's
  settings can be copied onto another. The default reproduces the historical key
  byte for byte, so an existing install keeps every per-display setting attached;
  switching is an explicit step and the transfer is separate rather than a silent
  re-key. The copy handles both storage shapes: the per-display key families *and*
  the network-device attachment, which lives inside one shared blob and would
  otherwise be left pointing at nothing. It refuses to overwrite settings the
  destination already has unless `--overwrite` is passed.
- **A DPCD/DSC decoder, driven by `fbdcli report --dpcd <hex>`.** The decoders for
  the DisplayPort Configuration Data block — revision, link rate and lane
  capability, per-lane training status, the DSC capability block, and HDCP's
  BSTATUS — are pure, and `report --dpcd` decodes a dump you supply, optionally
  with an address prefix (`68028:00`), because HDCP sits 400 kB away from the
  capability block. Reading DPCD *from* the hardware is not built: the private
  getters are located and symbol-verified, but their signatures are unknown, and
  calling one speculatively against a machine's only attached display is not a
  risk worth taking. A dump is treated as a set of ranges, and a register that was
  never read reports "not read" rather than zero — those are different claims, and
  a report that conflates them is worse than no report.
- **Two sibling projects reviewed, and the first of their ideas taken on.** Two
  free alternatives, FreeDisplay and Crisp, were read for what FBD lacks; both are
  MIT (Crisp ships a `LICENSE`, FreeDisplay declares MIT in its README but ships no
  licence file). The capability comparison, the licences, and Crisp's Apple-grounded
  UI doctrine are recorded in
  `docs/plans/reference-projects-freedisplay-crisp.md` — FBD is ahead on automation,
  network devices, streaming and EDID override, and behind on scaling finesse,
  named presets, localisation and a few cheap system controls.
- **The panel's chrome no longer stacks a material on glass.** The header, the
  settings header and the tools footer sat on `.ultraThinMaterial` *inside* a panel
  whose backdrop is already a frosted layer. They now use a flat `labelColor` shade
  (`FBDTheme.chromeBandOpacity`), so the panel holds one material rather than four —
  and three live blurs no longer re-sample the same backdrop on every redraw.
- **Keep the Mac awake.** A toggle in Settings → Menu → System holds a
  `NoDisplaySleepAssertion` while FBD runs, so a long transfer, render or
  presentation does not end with the display asleep. It is app-side by necessity:
  the assertion belongs to the process that holds it, so a `fbdcli` invocation
  would drop it on exit — which is why there is no command-line switch for it.
- **Several PiP windows at once.** Capture sessions are now keyed by their source,
  so a second display's PiP opens a second window instead of closing the first, and
  re-asking for a source replaces only that source's window. The app keeps one
  window per display, which *is* one window per source. `fbdcli pip` takes several
  sources in one invocation (`pip 1 --window 1234`), which is the only way to open
  two at once on a single-display Mac. Verified live: two windows coexisted and both
  tore down cleanly when the CLI's stdin closed.
- **A virtual screen can be associated with real displays, so an arrangement is
  recalled when it attaches.** `fbdcli config vscreen associate <screen-id>
  <display-id>…` records the arrangement the displays have at that moment. They are
  named by identity, so the association outlives the reconnect that reassigns display
  ids — the reason it is worth storing at all. Recall goes through the same
  `CGConfigureDisplayOrigin` path layout protection uses, so there is one place that
  knows how to talk to the display layer, and it fails closed: if any associated
  display is absent, nothing moves, because a partial arrangement would shuffle the
  displays that *are* present into positions chosen for a layout that is not.
  Mirroring is deliberately not implemented and has no stored flag — ADR-0001 records
  that a virtual screen cannot be addressed as a display, so a flag nothing could
  apply would be the dead configuration this codebase has had to remove twice.
- **GUI scale matching — and the physical-size data it needed.** `CGDisplayScreenSize`
  reports a real panel size (344×222 mm for this machine's built-in display), so the row
  carried as blocked on "reliable physical sizes" was blocked on nobody having called
  it. `Display` now exposes that size and the GUI scale it implies — logical points per
  millimetre, which is what determines how large the interface actually looks — and
  `UIScaleMatching` picks, for each display, the mode whose scale is closest to a
  reference. Two things are deliberate: distance is *relative*, so 5→6 and 6→5 are
  equally far apart, and the choice fails closed — if no mode gets within tolerance
  nothing changes, because moving every window on a display without achieving the match
  is worse than leaving it alone. `fbdcli config uiscale` reports each display's scale
  and what it would do, and toggles the setting; it reports rather than applies, since a
  resolution change moves every open window.

### Changed
- **The panel is one surface now: rows are bands, not cards.** The three rounded cards that floated
  inside the panel — the display row, Virtual Screens and Display Groups — each carried their own
  fill and a hairline border, which is the glass-on-glass stacking the chrome fix was about, one
  level down. They are full-width bands of `Color.primary.opacity(0.035)` (`fbdPanelBand()`)
  separated by hairlines, so the expanded detail region sits *in* the panel's surface rather than on
  a card inside it. `fbdCard()` remains for Settings, where a group genuinely is its own surface.
  Checked against the rendered panel rather than the source: no rounded corners remain on rows, and
  the expanded detail reads as part of the band.
- **The brightness/volume HUD is configurable.** Position (top centre/left/right, bottom
  centre), a continuous or a segmented bar, a dark HUD or one that follows the system
  appearance, a shadow toggle, and a corner-radius slider. The defaults reproduce the
  previous appearance exactly, so an untouched install is unchanged, and every value is
  clamped — a stored radius cannot clip the content. The HUD's content now carries its own
  foreground, which also fixes unreadable text on the dark HUD in light mode.
- **Dock visibility rules.** A menu-bar app is an accessory by default; it can now be given
  a permanent Dock icon, or a brief one at launch so it is findable in the Dock just after
  it opens.
- **The menu-bar panel is flattened.** Each display is now one compact row: icon, name,
  capability badges, current mode, the options menu and the power button on the title
  line, with the brightness slider and its nits value inline beneath it. Filters, DDC/CI
  and the resolution/XDR sections moved behind a single **More controls** disclosure.
  Before this, one display filled most of the 650pt panel, so a multi-display Mac could
  not see its own displays at once — the one thing the panel exists for. Nothing became
  unreachable: the ⋯ menu already covered mode, refresh, colour, presets, favourites,
  mirror, PiP, rotation, disable and Open in Settings, and the folded content is unfolded
  in Settings → Displays.
- `Settings.debugSummary` now includes the lock-dim, keyboard-target and
  brightness-model settings.
- `fbdcli help` documents `config`.

### Fixed
- **"Prefer hardware brightness" and the curve's dimming zone now work, and a brightness read now
  agrees with the screen.** All three needed the same thing: FBD applied software brightness as an
  overlay but neither tracked nor reported it, so a read returned the backlight value while the
  screen showed something dimmer — the read-back-disagrees-with-the-screen bug
  `CombinedBrightness` documents itself as having fixed once already. The dim is now tracked per
  display and reported by `get`; the overlay gives the brightness route its **own** dim source
  beside the dim-to-black/lock one, combined as the darkest of the two so releasing either leaves
  the other in force. On that footing `preferHardwareControl == false` delivers brightness as a
  dim over the backlight — falling back to the hardware when the request is brighter than the
  backlight, because a dim can only ever lower what the screen shows — and the curve's
  `minHardwarePercent` / `softwareZeroPercent` ramp the hardware and dim the rest, releasing the
  dim once the route climbs above the ceiling. The dim is taken only where it outlives the call, so
  a one-shot `fbdcli` invocation keeps the hardware route rather than accepting a write that would
  vanish. The shipped profile takes neither route, so a default install behaves exactly as before.
- **Four brightness-model sliders shaped nothing; two of them do now.** The combined-curve
  model (`BrightnessCurve`) had no caller at all — `XDRBoostPlanner` computes its own linear
  map — so the "Upscaling maximum" and "Software dimming switchover" sliders in Settings were
  inert. `upscaleMaxPercent` now caps how far an upscale may reach, on the native nits target
  as well as the software-boost factor, and `dimmingSwitchoverPercent` moves where that boost
  ramps. Both take effect only when the profile carries them, so a shipped profile behaves
  exactly as before. The other two knobs — "Minimum hardware level" and "Redefine 0% software
  brightness" — belong to the curve's dimming zone, which needs software-brightness state FBD
  does not track; `get` does not report an overlay dim, so honouring them would make read-back
  disagree with the screen, which is precisely what `CombinedBrightness` documents itself as
  fixing. The row records that rather than half-wiring it.
- **The startup control-value policy works now.** Settings offered "assume last used / write
  to device / read from device" and nothing read it: FBD had no store of per-display control
  values for it to act on, so a visible picker could not do anything. `DisplayController`
  now records the brightness it sets, per display identity, and launch reads it back,
  re-writes it, or leaves the device alone as asked. Absence is stored as absent rather than
  0, because 0 is a legitimate brightness — and the default policy touches nothing, so a
  default install behaves exactly as before. Verified live: with `write`, a stored 0.4
  reached the panel (38.6% after backlight granularity); with `read`, a deliberately wrong
  0.99 was corrected to the device's 0.3898 **without changing the device**; with `assume`,
  nothing happened at all.
- **"Allow unsafe modes" did nothing; now it does.** The setting was written by the
  Settings page and read by nobody — every mode list came straight from the raw list — so
  the switch changed nothing while appearing to work. The offered list now runs through
  `ModeFilterOptions` (`Display.offeredModes`) in the panel's Display Mode menu, the
  per-display sections and `fbdcli modes`, which also reports how many modes it hid. Every
  other filter rule is deliberately left permissive: `standard`'s view hides the scaled
  ("mixed") resolutions macOS itself provides — six on this machine — so wiring that view
  in wholesale would have silently removed resolutions people could pick. That regression
  is what the live before/after count caught, and there is a test for it now.
- **Settings → Back discarded a resized panel.** Going back restored a hard-coded
  460×650, so a panel the user had widened snapped back to 460pt wide (the saved
  frame on this author's machine is 535pt). The size the panel had when Settings
  opened is now remembered and restored on the way back, clamped to the panel's
  minimum, so a deliberate resize survives the round trip.

### Verification
- `swift build --disable-sandbox` — clean, **zero warnings**.
- `swift test --disable-sandbox` — **868 tests, 0 failures** (FBDCoreTests 732,
  including the 266 test seams added by the parity work; FBDCLIParserTests 136).
- `make ui-smoke` — 5/5 against the rebuilt app.
- CLI round-trips verified against the live app for every `config` subcommand,
  including the refusal paths.

### Not in this change
- The menu-bar quick menu was **not** restructured to mirror BetterDisplay's
  grouped layout; only Settings was. Recorded as open.
- The HTTP API stops short of group *sync apply*: it is reachable from `fbdcli` and the
  app UI, but exposing it needs more than a route. Group sync matches brightness in nits,
  which means the executor's `DisplayControlling` seam would need `hardwareCeilingNits`
  added, otherwise the endpoint would silently skip the luminance matching the CLI does.
- No new private API was introduced, so `docs/PRIVATE_APIS.md` does not change.

## [1.6.0] — 2026-10-04

### Added
- **A feedback layer.** There was no loading or error state anywhere in the UI
  (`grep -rn ProgressView Sources/FBD/` returned nothing).
  - `FBDStatus` + `FBDStatusLine`: an inline working/failed/succeeded line with a
    single combined VoiceOver announcement.
  - `FBDNotice` + `FBDNoticeBanner`: an app-level surface for menu-initiated
    actions, which need one because a menu dismisses on selection and a status
    line inside it would never be read.
  - The DDC panel shows a spinner while probing, then a checkmark or an explicit
    "No reply from the display".
- **DDC inputs are offered by name.** When a display reports which inputs it has
  (the VCP 0x60 value list in its capabilities reply), the panel offers those by
  name — "HDMI 1", "DisplayPort 2" — and shows anything outside the MCCS table as
  `Input 0xNN` rather than attaching a plausible-looking wrong label. Only values
  that the display itself reports are offered, and the raw field remains as a
  manual override.
- `FBDCard` — the display-card surface, previously copied byte-identically into
  four views.
- `fbdIconButton()` — a 28pt hit target for icon-only controls, applied to seven
  of them. A bare `Image(systemName:)` in a borderless button is only as large as
  its glyph (roughly 12–16pt), which is easy to miss deliberately.

### Changed
- **A design-review pass over the whole UI**, driven by an Impeccable critique
  (24/40 on Nielsen's heuristics, run as two isolated assessments: a design
  review and a technical/accessibility evidence pass).
- **Motion now matches the product register.** `FBDTheme.animationSpring` was a
  280ms spring with `dampingFraction 0.7` — i.e. bounce — where a tool the user
  is mid-task with should use 150–250ms eased and no bounce. Renamed to
  `animationPanel`, since it no longer described itself correctly.
- 32 spacing/padding literals routed through `FBDTheme` tokens, value-identically.

### Fixed
- **`Read capabilities` froze the UI while it ran.** The DDC probe blocks (a
  settle sleep plus up to three I2C reads) and its only caller was `@MainActor`,
  so the main thread stalled for the whole probe. A spinner would have been a
  lie, because SwiftUI cannot draw while that thread is blocked — so the read now
  runs on the per-display queue and reports back on the main actor. The same
  blocking applied to the panel's contrast/volume/mute read-back.
- **Controls that silently did nothing now say so.** The DDC panel's input
  "Apply" returned early on an invalid value with no feedback of any kind; it is
  disabled until the field holds a usable value, with help text naming the range.
  Rotation and mirror/unmirror results were discarded, so a refused action closed
  the menu and looked dead; both now surface.
- **`Configuration Protection` misrepresented its own scope.** It was a
  per-display menu toggle over one *global* flag, and enabling it saved only the
  display whose menu it was flipped from — leaving every other display apparently
  protected with nothing stored. It lives in Settings now, beside Layout
  protection, and snapshots every online display.
- **`Show in Settings` promised navigation it never performed.** It posted no
  payload and Settings had no target-display concept, so it landed on the
  Overview page showing nothing about the display. It now opens the Per-Display
  tab and scrolls to that display.
- **`Mirror Display` opened empty on a single-display Mac**, because its targets
  are other *online* displays. It is disabled with a reason instead.
- **A display with no DDC/CI now says so** rather than silently omitting the
  panel, which read as a bug rather than as an absent capability.
- **The arrangement grid's display names were unreadable in light mode** — 9pt
  white on a 25%-opacity accent fill, roughly 1.5:1. Non-dragging tiles use
  `.primary`, which adapts to the appearance.
- **`release.yml` looked for the wrong CHANGELOG heading.** It searched for the
  tag form while headings are written without the `v` — so every release after
  1.4.0 would have shipped with empty release notes. The search is now anchored to
  the start of a line, because an unanchored pattern also matches a passing
  mention of a heading inside prose and then the notes begin mid-sentence.

### Accessibility
- **Four controls had no accessible name.** The automation rule toggle and its
  three pickers were built as `Toggle("")` / `Picker("")` with `.labelsHidden()`
  — which hides a label *visually* but still exposes it, so an empty one left
  VoiceOver with nothing to announce. They now carry real hidden names, and the
  rule's remove button has an accessible label alongside its tooltip.
- **Reduce Motion was bypassed in two places.** The footer's expanders animated
  regardless of the setting, in a file that already guards four other animations.
  A `reduceMotion ? .opacity : .opacity` ternary had identical branches, so it
  did nothing while appearing to handle the setting.

## [1.5.0] — 2026-10-03

### Fixed
- **Built-in display disconnect is refused on base-M3 MacBooks.** On Macs with the
  base M3 chip (M3 MacBook Air, entry-level M3 MacBook Pro) Apple repurposed the
  built-in panel's connection for clamshell two-display support, so a
  soft-disconnected built-in display may not come back without a reboot. The
  decision lives in `BuiltInDisconnectGuard` (pure, unit-tested) and is enforced at
  the single `DisconnectController.setEnabled` chokepoint, so the CLI, the per-display
  UI and the auto-disconnect path are all covered. The explicit override ships off
  and is offered in Settings only on affected hardware.
  (BetterDisplay ships the same guard — waydabber/BetterDisplay#4723.)

### Added
- **Full-screen filters gained sharpening, geometry and custom 3D LUTs**
  (BetterDisplay 5 parity). `ScreenFilterParams` now carries `sharpness` +
  `unsharpRadius`, `zoom` + `offsetX`/`offsetY`, and an optional `.cube` LUT
  path — all clamped **in the initialiser**, so no caller (CLI, HTTP, UI or App
  Intent) can push the Metal uniform block outside the range the shader is
  written against. The overlay applies them in one pass: a 4-tap unsharp mask
  on the neutral signal, zoom/pan in the vertex UV transform, and a `size³`
  RGBA float 3D texture sampled after the colour maths.
  - Zoom is clamped to ≥ 1 and pan to the margin the zoom leaves, so the
    clamp-to-edge sampler can never be dragged into view as smeared borders.
  - A LUT that fails to load is logged and the stage is skipped — a bad cube
    never takes the overlay down with it. `fbdcli filter` validates the file up
    front so a bad path is a clear CLI error instead.
  - `fbdcli filter` gained `--sharpness`, `--radius`, `--zoom`, `--pan x y` and
    `--lut path`; the same optional fields are accepted by the HTTP `filter`
    route; the filter disclosure row has the matching controls, including a
    LUT picker. `fbdcli help` now lists the `filter` command at all.
- `LUTCubeParser` for Adobe `.cube` 3D LUTs: UTF-8 **text**, `LUT_3D_SIZE`
  **2…128**, one-dimensional and mixed CUBEs rejected outright, `DOMAIN_MIN`/
  `DOMAIN_MAX` normalisation, and a byte cap checked before any float parsing.
  Every malformed shape yields a specific `LUTCubeError` rather than a crash or
  a partially-applied correction — a `.cube` file is user-supplied input.

### Changed
- `ScreenFilterArgs` (in `FBDCLIParser`) is the single parser behind both
  `fbdcli filter` and the routed HTTP plan, so the two can no longer drift.
- 102 new unit tests: `LUTCubeTests`, `ScreenFilterParamsTests`,
  `ScreenFilterArgsTests`, `PiPArgsTests`, `StreamArgsTests` and
  `DisplayAutomationTests`.

### Added (PiP sources + local streaming)
- **PiP can now capture a window or an application**, not just a display
  (BetterDisplay 5's "PiP for individual windows"). `PiPCaptureSource` carries
  `.display` / `.window` / `.application`, mapped onto ScreenCaptureKit's three
  filter constructors; a window is captured at its physical pixel size rather
  than upscaled, and an application composites all of its windows. `fbdcli pip
  list` enumerates capturable displays, windows and apps, and
  `fbdcli pip --window <id>` / `--app <bundle-id>` select one.
- **Local streaming** — `fbdcli stream <source-display-id> <target-display-id>`
  redirects one display's contents onto another, full-screen. It is the same
  capture + Metal pipeline as PiP, so it is the same controller with a
  `PiPPresentation` (`.floating` / `.fullScreen`) rather than a third copy of
  the ScreenCaptureKit plumbing. `fbdcli stream stop` ends it, and a
  "Stream to ▸" submenu does the same from the display options menu.
- Rejecting `stream <id> <id>` with the same display on both sides up front: it
  would capture the stream's own window and feed back forever.

### Added (per-display event automation)
- **Run a shell script or open a URL when a display connects/disconnects, or
  when the system sleeps/wakes** — BetterDisplay's per-display commands. This is
  the one place FBD executes arbitrary code, so it is deliberately the narrowest
  useful shape:
  - A rule exists only because someone created one; `enabled` gates it further;
    nothing is inferred or inherited. Off by default in the strongest sense —
    with no rules there is nothing to run.
  - Rules are addressed to one display's `identityKey`, or to "any display".
    A system event only ever fires "any display" rules, since a sleep cannot be
    attributed to a single display.
  - Every action is killed at `AutomationLimits.timeout` (default 10s, capped at
    120s) and rate-limited to one run per `minimumInterval` (default 5s) —
    topology changes arrive in bursts, so without it one dock event would run
    the same script several times.
  - Execution is on a **serial** queue: a concurrency limit of one, so an event
    storm cannot stampede the machine.
  - Actions receive `FBD_EVENT`, `FBD_DISPLAY_ID`, `FBD_DISPLAY_NAME` and
    `FBD_DISPLAY_IDENTITY` in their environment, and captured output is capped.
  - The decision layer (`AutomationScheduler`, `AutomationCommand`) is pure and
    the executor is an `AutomationExecuting` seam, so tests assert what *would*
    run without ever starting a process.
- `fbdcli automation list|add|enable|disable|remove|test|log`. Rules live in the
  shared suite, so one added from the CLI applies to the running app — the
  controller re-reads before each event rather than caching at launch.
- A Settings → Automation section listing every rule with its payload shown
  verbatim, an enable toggle, and an add form.

## [1.4.0] — 2026-08-04

### Added
- **Per-Display control page** — the per-display settings tab grew into a full
  control page (`PerDisplayCardView`), with each display's own sections rather
  than one shared list.
- **Drag-to-arrange display grid** — `ArrangementGridView` sets the arrangement
  by dragging displays directly. The geometry lives in a pure `ArrangementMath`
  (unit-tested in `ArrangementMathTests`) rather than in the view, and the path
  uses public CoreGraphics only.
- Two ADRs recording those decisions:
  `0001-no-virtual-screen-software-brightness` and
  `0002-display-arrangement-via-public-cg-api`.
- Engineering docs: `docs/agents/domain.md`, `docs/agents/issue-tracker.md`,
  `docs/agents/triage-labels.md`.

## [1.3.3] — 2026-08-04

### Fixed
- **Color-temperature filter was inverted** — dragging toward "Warm" made the
  screen bluer. The shader's r/b math is swapped (p<1 now = more red).
- **HTTP API default port was 0 (ephemeral)** despite the README promising
  8765 — the default is now 8765.
- **Media-key interception was silently ON** — now opt-in (default off) and
  documented.
- **DDC contrast/volume/mute UI was send-only** (always showed 50%) — the
  panel now reads the monitor's real values back.
- **Dead code removed**: IOMobileFramebufferAPI (an unimplemented "XDR
  direct" path the README claimed), the "Stream Display" menu twin of
  Picture-in-Picture, the FBDIntents placeholder.

### Changed (review-driven structure)
- LG webOS + Samsung Tizen controllers now share one WebSocket base
  (`WebSocketDisplayController`) — the duplicated receive loop / connection
  teardown is gone (LG 372→201, Tizen 403→275 lines).
- Routed CLI vocabulary has a single source
  (`HTTPRoutingPlanBuilder.supportedCommands`) instead of a second list in
  HTTPRouting that could drift.
- `DisplayRowView` (1068 lines) split into per-capability child views:
  DisplayOptionsMenuView, FilterControlsView, DDCPanelView,
  DisplaySectionsView, DisclosureSection — behavior unchanged.
- CLI helper shapes extracted: withDisplay / requireDisplayID /
  requireArgCount (repeated guard-and-fail blocks).
- IPv6 URL bracketing centralized in `NetworkHost.bracketed` (+3 tests).
- README documents the `fbd://open` URL scheme and the media-keys opt-in.

### Changed (deepening — combined brightness)
- **One deep `CombinedBrightness` module** replaces `CombinedController` +
  `CombinedRouting` + the hand-written fallback in
  `DisplayController.setXDRUpscaleTarget`. The nits ceiling math now lives in
  one place, and the **upscale-state invariant** holds on every path: the
  software-boost and hardware-stop branches of the slider always sync
  `display.isXDRUpscale`/`xdrUpscaleTargetNits`, so brightness read-back
  agrees with the screen (previously a slider-driven software boost left the
  flag stale). Interface: `get` / `set` / `setTarget(nil = off)`, behind
  four control seams (`AppleControlling`, `DDCControlling`, `XDRUpscaling`,
  `OverlayControlling` — the ExternalControlling test pattern).
- 9 new `CombinedBrightnessTests` at the new interface (route choice +
  state invariant + read-back agreement); `CombinedRoutingTests` /
  `CombinedRoutingPropertyTests` deleted per replace-don't-layer.
- `CONTEXT.md` added — domain glossary (Display, Brightness, Combined
  brightness, Hardware ceiling, XDR upscaling, Software boost, Upscale
  state).

### Changed (deepening — virtual displays, settings persistence)
- **Virtual displays route through the `DisplayControlling` seam** — the
  executor's virtual create/destroy/list go through one surface
  (VirtualScreenController behind the adapter), testable with a fake.
- **Closed the settings-persistence bypass**: XDRNativeController wrote its
  upscale target via `UserDefaults.standard`, invisible to the app when the
  CLI drove it — everything now goes through `Settings.defaults` (the
  suite-aware accessor). No direct `UserDefaults.standard` writes remain in
  FBDCore outside Settings.

### Changed (deepening — HTTP executor)
- **`HTTPExecutor` moved into FBDCore behind the `DisplayControlling` seam** —
  the whole local API surface (health, displays, controls, actions, virtual)
  is now testable with a fake; `AppCore.execute` shrank from ~120 lines to a
  thin wrapper supplying the adapter + app version. The router (path → route)
  and the executor (route → action) now live side by side in FBDCore.
- 11 new `HTTPExecutorTests` at the seam (health/list/info/controls/actions/
  virtual error paths).
- `ddcProbe` (a second DDC stack in the CLI) deleted — contrast/volume/mute/
  input/caps/ddc-test all read through DisplayController's single serialized
  stack (+ `readInputSource`, `readRawVCP`).

## [1.3.2] — 2026-08-03

### Changed
- **PiP window is now closable and resizable**: the window gained a standard
  title bar (transparent titlebar, hidden title) with a native close button
  and resize edges; closing tears the session down (windowShouldClose ->
  teardown). Verified live: corner-drag resize 480x270 -> 504x293, close
  button removes the window, app stable.
- **"Video Filter Window" renamed to "PiP"** everywhere (footer button,
  Tools menu item) — the old name was confusing since it opens a
  picture-in-picture window.

### Fixed
- **App crashed when a second virtual screen was created** (and at launch
  when an autoConnect config reconnected after one was already active):
  `VirtualDisplayAPI.takeError` took an owning reference to the framework's
  NSError, but the SL framework's error lifetime differs on the
  second-display failure path — the over-release crashed at the
  autorelease-pool drain (`-[NSError release] sent to deallocated
  instance`, confirmed with NSZombieEnabled). The error description is now
  copied via CF bridging without ever retaining/releasing the
  framework-owned object. Verified: 1st create works, 2nd/3rd creates fail
  cleanly ("failed via app"), app stays alive, launch reconnect survives.
  Note: creating more than one SLVirtualDisplay fails on this macOS 27 —
  now a graceful error instead of a crash.

### Changed
- **UI simplification sweep** (feedback: "confusing / overengineered / footer
  buttons do nothing"):
  - Removed the per-card quick-toggles row (HiDPI / Auto Brightness / Notch);
    HiDPI and Auto Brightness moved into the display's options menu, and the
    dead Notch toggle was removed entirely.
  - Tools footer rebuilt: it is now pinned to the panel bottom (it floated
    mid-window when content was short) and every button has a visible action
    — Virtual Screens / Groups expand their sections (verified via AX), PiP
    opens the floating window, Check for Updates and Quit work. The subtle
    scroll-jump Tools menu and the System Colors button were removed.

### Changed
- **Image Adjustments moved out of the options menu into a card "Filters"
  disclosure** — sliders inside SwiftUI menus are fragile (they close on
  accidental clicks and are hard to hit); the disclosure matches the card's
  other sections. Verified live: dragging the saturation slider to 0 makes
  the screen measured-grayscale (colorfulness 0.0000), Reset restores it.

### Changed
- **Adaptive panel-height experiment reverted**: fitting the panel to the
  SwiftUI content on display changes fought the hosting controller (window
  grew past the 900pt max to 1008). The panel stays at the fixed 650/860
  sizing; the pinned footer remains. (Dead-band cosmetic with a single
  display is acceptable versus unstable window sizing.)

## [1.3.1] — 2026-08-03

### Fixed
- **Tools footer wrapped into a multi-line mess at 460pt**: collapsed into a
  single compact "Tools" menu (Displays / Virtual Screens / Groups / Video
  Filter Window / System Colors / Check for Updates / Quit) plus one quick
  Video Filter Window button.
- **Each "Video Filter Window" click spawned a new window** (rows and footer
  each owned a PipStreamController instance; teardown used async orderOut
  only, which leaves windows composited on this system): the controller is
  now a shared singleton and stop() detaches + drops references
  synchronously. Verified: 3 consecutive clicks -> exactly one window, no
  crash (an earlier close()-based attempt over-released and segfaulted —
  isReleasedWhenClosed stays false; the window deallocates via reference
  drop).

## [1.3.0] — 2026-08-03

### Added
- **Full-screen Image Adjustments** (the last UI gap): per-display software
  filter with live contrast / saturation / gamma / color-temperature
  sliders and an invert toggle, rendered by the SCK+Metal overlay (the same
  pipeline as the XDR boost). `ScreenFilterParams` + `setScreenFilter` on
  the controller, CLI (`fbdcli filter <id> <contrast> <sat> <gamma> <temp>
  [--invert] | off`) and routed HTTP API. Verified live: saturation 0 ->
  measured colorfulness 0.0000 with luma preserved, reset restores exactly.
- **Screen Rotation** (0/90/180/270): `SLSSetDisplayRotation` declared and
  wrapped (SkyLight), wired into the options submenu + `fbdcli rotate`.
  NOTE: the SLS call returns status 1001 for the built-in on this system —
  graceful failure; external-display verification pending (recorded).
- **fbdcli rotate / filter** commands (direct + routed through the app's
  HTTP API; the CLI process's own SCK overlays do not composite, so the
  routed path is the working one — single-driver).
- HTTP API: POST /api/displays/<id>/rotate and /filter (+ off); router
  tests (270 total).

### Added
- **Per-display options menu** (ellipsis in each display card): Display Mode
  (all modes with current marker), Refresh Rate (unique Hz values),
  Color Mode (profiles), Apple Display Preset (XDR presets), Mirror Display
  (per-target mirror/unmirror via display groups), Stream Display and
  Picture in Picture (floating video-filter window), Image Adjustments
  (video-filter window + live contrast/saturation sliders), Move Display
  (Set as Main Display via CGConfigureDisplayOrigin), Screen Rotation
  (honestly disabled — unsupported), Configuration Protection (lock current
  settings), Manage Display (disable/re-enable gated by the new setting).
- **Quick-controls row per display**: HiDPI toggle (same-size mode
  variant), Auto Brightness toggle (hardware ambient-light compensation,
  hidden when unsupported), Notch toggle (disabled — unsupported).
- **Tools footer**: Displays And Virtual Screens (scroll-to menu), Groups,
  Video Filter Window (opens a real PiP stream), System Colors (System
  Settings → Displays), Check for Updates, Quit FBD.
- **Settings tabs**: Overview / Per-Display segmented control; the
  per-display tab lists each display (offline included when enabled) with
  its mode, brightness and connect/disconnect controls.
- **New settings**: Show offline displays in Settings; Enable
  connect/disconnect for displays (gates the power/disable controls).

### Changed
- `DisplayController`: ambient-light compensation passthroughs and
  `setAsMainDisplay` (CGConfigureDisplayOrigin to (0,0)).

## [1.2.1] — 2026-08-03

### Fixed
- **Software XDR boost rendered the screen out of focus**: the ScreenCaptureKit
  capture used the display's point size (1728×1117), so the overlay redrew a
  2x display at half resolution. The capture now uses the physical pixel
  resolution (CGDisplayPixelsWide/High — 3456×2234 on the built-in).
  Verified: overlay layer resolution 1728×1117 → 3456×2234, and edge energy
  with boost on stays at ~0.91 of the unboosted screen (was heavily blurred).

## [1.2.0] — 2026-08-03

### Changed
- **UI overhaul** — premium floating-glass panel (Control Center-style):
  - Design system (`FBDTheme`, `FBDTag`, `DisplayKind`) — semantic system
    colors, shared spacing/radii/motion tokens, full dark/light adaptation.
  - Frosted-glass panel background (`NSVisualEffectView` behind transparent
    window) with rounded cards for display rows, virtual screens and groups.
  - Custom slider (`FDBSlider`) — gradient fill, floating thumb, hover/active
    micro-animations, XDR "boost zone" divider; keyboard arrows and VoiceOver
    adjustable-action support.
  - Brightness control now shows a live nits estimate on XDR displays and a
    hardware→XDR zone marker; badges distinguish Built-in / External (DDC) /
    Virtual / XDR displays.
  - Display cards: kind icon tile, capability tags, redesigned DDC panel,
    icon-labeled disclosure sections.
  - Settings regrouped into icon-labeled sections; HTTP note updated
    (applies immediately, no restart); About section with app tile.
  - Reduced Motion respected throughout.
  - **Top-bar overlap fixes** (feedback pass): a reserved 28pt frosted
    titlebar strip so content never slides under the traffic lights, with
    the bar's material extending up into the strip so the traffic lights
    sit ON the bar (unified-toolbar look) instead of floating above it; the
    bar is a single row — traffic lights and content share the band (64pt
    light clearance, content beside them), no empty gap under the buttons; the
    main header is now a fixed elevated bar (material + hairline divider,
    gear moved in from the toolbar) instead of floating; Settings got its
    own fixed header bar with a **Back** button (there was no way back
    before) and the panel grows to 460×860 on settings open (top-anchored)
    and shrinks back on Back.

### Fixed
- **XDR software boost was dead on write-protected systems** (found via live
  testing with a real Screen Recording grant): the explicit
  `xdr <id> <nits>` command always chose the native preset path when the
  display was XDR-capable, so on macOS 27 (write-protected preset slots) it
  failed without ever trying the software overlay. `setXDRUpscaleTarget`
  now falls back to the software boost when the native write fails.
- **Boost overlay never composited**: the renderer presented Metal drawables
  manually from the capture queue on a paused MTKView, which renders nothing
  on this system. Switched to the MTKView-delegate draw pattern (frames
  stored on the capture queue, drawn on the main thread).
- **Boost overlay leaked after "off"**: tearing down could race the session
  deallocation and leave the last brightened Metal frame frozen on-screen
  (the screen stayed boosted until the app quit). Teardown now hides the
  window synchronously (alpha 0 + orderOut) before stopping the stream, and
  overlay windows are `isReleasedWhenClosed` so close() destroys them.

### Changed
- `GET /api/health` now reports `boostActive` (display IDs with a live
  software-boost session) — observability for the overlay.

### Fixed
- **Panel showed "Brightness unavailable" at launch**: nothing performed an
  initial brightness read — the value only appeared after a write or an
  external change. `DisplayController.refresh()` now reads each
  brightness-capable display once at enumeration.
- **Top bar sat ~34pt below the traffic lights**: the SwiftUI root was
  inset by the titlebar safe area despite `.fullSizeContentView`; the root
  now uses `.ignoresSafeArea()` so the material bar actually extends up
  under the buttons.

### Verified (with Accessibility permission granted)
- Full UI flow driven end-to-end: status-item click opens the main page,
  the custom brightness slider sets real brightness (24.8% / 71.4%
  read-backs), the gear opens Settings (window grows to 860), Back returns
  to the main page (650), the close × hides the panel. Button hit areas
  were verified against the live Accessibility frames.

### Fixed
- **Settings toggles turned gray after the panel lost focus**: the panel is
  a `.nonactivatingPanel` that rarely holds key status, so SwiftUI rendered
  every control in the gray "inactive" variant whenever another window had
  focus (observed live: switches blue on first open, gray after clicking
  outside). The panel root now forces `controlActiveState = .key`, and the
  settings switches get an explicit `.tint(.blue)` on-state. Verified by
  pixel-sampling the switch fill while focused and unfocused (both blue).

### Added
- AppIntents bridge (`FBDAppIntentsBridge`) so the Shortcuts actions from the
  `FBDIntents` module are discoverable by macOS (previously compiled but
  unreachable from Shortcuts).
- `fbdcli list --json` — machine-readable output using the same serializer as
  the app's HTTP API.
- Media-key interception status surfacing: the Settings panel shows an
  "Media keys unavailable" hint when Accessibility permission is missing or
  revoked; the event tap auto-re-enables after system suspension and retries
  installation when the app is re-activated after granting permission.
- Accessibility labels: status-bar button, panel close/settings buttons,
  per-display brightness sliders (label + percent value).
- Right-click status-item menu (Show FBD / Settings… / Quit FBD);
  `fbdcli settings` masked settings dump for bug reports; `GET /api/health`
  unauthenticated endpoint.
- Parser fuzz sweeps (EDID/VCP/capabilities, 1,200 seeded iterations) and
  Swift-6-readiness fixes (NSLock → `withLock` in async contexts).

### Fixed
- XDR upscaling on macOS 27: the software boost fallback now defaults ON and
  is reachable from the explicit `xdr <id> <nits>` command (previously only
  the combined slider path fell back, and the default disabled it — the
  documented macOS 27 path was dead out of the box). The combined slider's
  below-ceiling path now stops an active overlay boost (the overlay does not
  set `isXDRUpscaled`, so the screen could previously stay brightened after
  dragging below the ceiling), and `isCombinedCapable` accepts the software
  fallback when the native path self-tests as write-protected. The overlay
  itself requires **Screen Recording** permission (documented in README).
- Routed `virtual destroy <name>` sent the raw name as the config id; names
  are now resolved to persisted ids before calling the app.
- Routed `virtual create` ignored the `isHDR` flag from the request body
  (hardcoded `false`).
- EDID overrides are now structurally validated (size 128–512, multiple of
  128, header, base-block checksum) at the CLI, controller and persistence
  gates — garbage can no longer reach the display registry or the
  auto-apply store.
- `Display.isVirtual` now uses an authoritative, cross-process registry of
  FBD-created virtual display IDs (persisted in Settings); the magic-ID
  fingerprints remain only as a fallback for Sidecar/AirPlay displays.
- HTTP server: declared `Content-Length` above 1 MB is rejected with 413
  before buffering; `Expect: 100-continue` is acknowledged so curl/URLSession
  clients no longer hang.
- `ColorProfileController` no longer force-unwraps the ColorSync UUID (crash
  when a display disconnects mid-flight).
- Release builds no longer silently copy a stale binary when the build fails
  (Makefile fails loudly now).

### Added (cycles 31-41)
- `fbdcli info <id> --json`; `fbdcli settings` masked dump (cycle 13);
  zsh completion (`completions/_fbdcli`).
- Live HTTP server reconciliation: `fbdcli http on/off` applies without
  an app restart (Settings watch + poll).
- `make bump-version`; secrets-ready release workflow
  (`.github/workflows/release.yml`).

### Fixed (cycles 31-41)
- `pip` controller instance mismatch (start/stop used different
  instances) — now shared.
- `applyMode` failures surfaced: the HTTP API returns 500 and `fbdcli
  set-mode` exits 2 instead of reporting false success.
- SIGTERM now routes through `NSApp.terminate` so AppKit cleanup runs on
  `kill` (cycle 27).
- XDR upscaling fallback on macOS 27: software boost defaults on, the
  explicit `xdr` command falls back to the overlay, below-ceiling drags
  stop an active overlay boost (cycles 21-22, planner-tested).
- Mode-spec and `tv` brand leniency fixes (cycles 17, 23).

### Verified (cycles 31-41)
- Close-read audit series across every remaining path (2 real fixes
  found, rest clean); memory-leak audit (framework-internal only);
  dependency drift (all current); full 23-command live regression matrix
  (cycle 30); launch-captured settings audit (clean); repo hygiene.

### Added (cycles 22-29)
- `XDRBoostPlanner`: the XDR fallback decision chain is a pure, tested layer
  shared by the slider and the `xdr` command.
- `completions/_fbdcli`: zsh tab-completion for all 32 commands and
  subcommands.
- Release workflow (`.github/workflows/release.yml`): tag-triggered
  sign/notarize/publish when the five secrets are configured; graceful
  unsigned-artifact fallback otherwise.
- `make bump-version VERSION=x.y.z [BUILD=n]` release helper.
- Shell/observability: `fbdcli settings` (masked dump), `GET /api/health`.

### Fixed (cycles 22-29)
- XDR upscaling on macOS 27: the software boost fallback now defaults ON and
  is reachable from the explicit `xdr` command; the below-ceiling slider
  path stops an active overlay boost; `isCombinedCapable` accepts the
  fallback when native preset writes are write-protected. The overlay needs
  **Screen Recording** permission (documented).
- SIGTERM now routes through `NSApp.terminate` so AppKit cleanup
  (willTerminate observers, e.g. the EDID factory restore on quit) runs on
  `kill`/session end.
- Mode-spec leniency: `1920x1080@` / `1920x` are rejected instead of
  silently dropping the trailing part.
- `fbdcli tv` brands match case-insensitively (`LG` now works).

### Verified (cycles 22-29)
- Memory-leak audit: no application-code leaks (framework-internal XPC
  allocations only).
- `fbd://` URL scheme end-to-end (brightness URL + malformed-input
  robustness); startup latency 0.57 s; help covers all 32 commands;
  full 23-command live regression matrix clean.

### Changed
- UI: the status-item popover is now a floating `NSPanel` (title bar + close
  button, resizable 420×500–600×900, frame autosave, Escape/⌘W close,
  NavigationStack with a natural back button from Settings).
- CLI parsing moved to a testable library (`FBDCLIParser`); command
  vocabulary and `--direct` handling are unit-tested.
- HTTP request routing (auth, method, path, body validation) moved to
  `HTTPRouter` in FBDCore with full test coverage; the app only executes
  typed routes.
- DDC: VCP reads retry (configurable `ddcReadRetries`), settle time is
  configurable (`ddcSettleMilliseconds`), capabilities replies must contain a
  complete `vcp(...)` group (single-level sub-values supported).
- App icon: generated squircle (`Sources/FBD/Resources/make_icon.swift` →
  `FBD.icns`) wired into the bundle.

## [0.1.0] — 2026-07-31 (scaffolding)

### Added
- Initial SwiftPM structure: FBDCore library, menu-bar app, `fbdcli`,
  `FBDIntents`, `CPrivateAPI`.
- Tier 1: Apple + DDC/CI brightness, contrast, volume, mute, input source,
  resolution/refresh-rate control, capabilities parsing.
- Tier 2: XDR/HDR brightness upscaling (native preset path + software
  overlay fallback), presets.
- Tier 3: virtual displays (SL path on macOS 26+, CG fallback on 13–15),
  layout protection, display groups.
- Tier 4: EDID export/override, color profiles, underscan, config protection.
- Tier 5: PiP streaming, custom OSD, Night Shift / True Tone, network TV/AVR
  control, local HTTP control API, App Intents, Sparkle auto-update wiring.
- Reverse-engineering notes for BetterDisplay internals.
