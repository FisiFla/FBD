# Changelog

All notable changes to FBD. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: semver from 1.0.0 (the first release with an update feed).

## [Unreleased]

## [2.1.4] - 2026-10-22

### Changed
- The Application page now groups the HUD settings together, right under "General". The "Custom
  OSD" switch — which turns the brightness HUD off — sat in the "Integrations" group next to the
  HTTP API, below the fold of the settings window. It now opens a group of its own, "On-screen
  display", with the switch and the HUD's position, bar, background, shadow and corner radius; the
  Dock icon options moved to a "Dock" group next to it.

## [2.1.3] - 2026-10-22

### Fixed
- The brightness slider drew a blue ring around itself. The slider's focusable view is the whole
  row — both sun icons included — so macOS's keyboard-focus effect was drawn as a border around
  the control instead of as a focus indicator. The thumb already grows when the control has the
  focus, which is the indicator this design uses; the system's ring is switched off.
- The brightness HUD popped up for changes FBD did not make. Every brightness change FBD observed
  was announced, including the ones the hardware made on its own — the brightness keys, the
  ambient-light sensor, another application — so the pill appeared on its own, often. The update
  now carries where it came from, and only FBD's own changes are announced. The HUD stays for the
  writes FBD performs, because macOS shows no indicator of its own for a brightness change an
  application makes.

### Documentation
- The install notes now say what an unsigned update costs: macOS treats the new binary as a new
  app, so Screen Recording is requested again and the login Keychain asks for its password once
  more (the app stays responsive while it does). `SECURITY.md` explains why the Keychain item's
  access control list is not widened to avoid the prompt.

## [2.1.2] - 2026-10-20

### Fixed
- The app could freeze solid when macOS asked for Keychain access. Reading the HTTP API token
  touches the login Keychain, and `SecItemCopyMatching` blocks on the modal "allow access?"
  prompt when the running binary is not in the item's access control list — which is exactly what
  happens after an update, because an unsigned build's identity is its code hash. The read ran on
  the main actor, so the prompt froze the menu bar, the settings window and every HTTP request
  (they all wait for the main actor) until it was answered. The token is now read off the main
  actor, cached, and served from memory afterwards; the prompt can still appear once per unsigned
  update, but the app stays usable while it is on screen.

## [2.1.1] - 2026-10-20

### Changed
- The feature matrix now says what was measured rather than what was inherited. Every cell that
  reads *live-verified* was measured on this machine (M1 Max, macOS 27.0.1, built-in XDR panel,
  2026-10-20): the brightness write, the resolution write, Night Shift, the display presets, the
  software overlay, the OSD, the PiP enumeration, True Tone and the HiDPI install script. The
  evidence lives in `docs/PRIVATE_APIS.md`, which also lists what this machine cannot show:
  DDC/CI on an external monitor, EDID on the built-in panel, the below-floor blend's DDC floor,
  the three display-connection behaviours, the privileged HiDPI write, and the app's own Screen
  Recording grant.

### Fixed
- The full-screen overlay could latch on a blank white screen. The capture excluded the overlay
  by window id, but that id was matched against a snapshot of the window list taken microseconds
  after the overlay had been ordered front — when the overlay was not in the snapshot yet, the
  capture included the overlay itself, and the overlay then rendered its own output for ever. The
  overlay windows now sit below the screen-capture shielding level instead of on it, the capture
  waits (briefly) for the overlay to be known and falls back to excluding the application, the
  window stays invisible until a real frame has been drawn, and a session that never receives one
  is torn down and reported instead of painting.
- The below-floor brightness blend never engaged. A request below the panel's floor was served by
  the software-dim route, which released the blend and left the screen at the floor while the
  slider said otherwise. The blend now decides before the dim route does, and only one software
  dim can be in force per display.
- The blend's read-back reported the floor instead of the position that was asked for. It decided
  "is the blend pinning the hardware?" by asking the hardware whether it sat at the threshold — a
  condition that is also true of the normal case, and that a read which has not caught up with the
  write yet fails. The read-back now follows the software factor, the one piece of state that says
  the blend is in force: 5 % in, 5 % out.
- Turning a full-screen filter off left its parameters behind, so the next composition restored
  the old cast and a stale software boost kept the screen brighter than the brightness slider
  said. "Off" now clears the user's filter parameters; the boost and the blend keep their own
  state, because they belong to the brightness route.
- The display model could claim an XDR upscale that was not on screen. The "is a software boost
  active?" question was answered with the model's own flag — the one the boost itself writes — so
  the flag could never clear itself once the session that owned it was gone, and the brightness
  read-back reported a brightness the screen was not showing. The live overlay session decides
  now.
- The feature matrix said the True Tone toggle *degrades* on macOS 27. It does not: measured on
  macOS 27.0.1 (built-in XDR panel, 2026-10-20), `CBTrueToneClient`'s `available` is true, `enabled`
  reads back and `setEnabled:` round-trips — off reads back off, on reads back on. The claim came
  from a note in Lunar's `CBTrueToneClient.h` (not controllable from third parties since macOS
  26.3) that was never measured here. The matrix, the private-API ledger and the controller's
  comment now say what was measured; the macOS 26 cell is marked unmeasured instead of degraded.
- The matrix said EDID is available on macOS 27. Measured: the built-in panel exposes none
  (`fbdcli edid export 1` → "no EDID available"), which the private-API ledger already said.
  EDID now has its own row, and external displays stay unverified.
- The matrix said the XDR native preset rewrite works on macOS 26. It is refused on macOS 26 and
  later — the controller's own self-test detects the rejected write — so both columns now point
  at the software boost and the footnote says why.
- `fbdcli xdr <id> <nits>` printed "upscaling enabled" when the write had in fact fallen back to
  the software boost. The boost lives in an overlay, and an overlay does not outlive a one-shot
  command, so the brightening was gone the moment the CLI exited. The command now says that
  instead of claiming a lasting change, and it names the read-back.

### Documentation
- `docs/PRIVATE_APIS.md` gained a "Live-verified on this machine — 2026-10-20" section: what was
  measured, the two measured facts that change a claim elsewhere (the True Tone note inherited
  from Lunar, and the macOS 26+ refusal of the XDR preset rewrite), and what this machine cannot
  show.
- A new test runs the generated HiDPI override install script against a temporary root: the plist
  is written and carries the ladder, `plutil -lint` accepts it, a repeated install is
  byte-identical and leaves no staging file behind, and the removal takes exactly that file away.

## [2.1.0] - 2026-10-20

### Added
- `fbdcli report [<id>][file] [--json]` is a paste-ready bug report: masked identity, geometry,
  mode, control paths, EDID, panel facts and the sink's DPCD (issue #19).
- `fbdcli skill install claude|codex` writes an agent-ready, version-stamped `SKILL.md`: the
  command grammar, the token model and a read-back command for every state-changing command
  (issue #31).
- The capabilities the other issues added are now reachable from all three surfaces: the
  HTTP API gained `disconnect`/`reconnect` (with `remember`), `hidpi` and `gamma-floor`
  actions, five Shortcuts actions were added, and the CLI grew the matching commands.
- Three display-lifecycle features (issue #30): a display can be kept disconnected across
  reboots until the user re-enables it; the built-in display can be turned off while an external
  display is attached and the lid is open, as a setting rather than a silent action; and an
  external display can follow the built-in panel's auto-brightness.
- A below-floor blend lets the software layer carry the range below the panel's floor, so the
  bottom of the brightness slider is no longer a dead zone (issue #29).
- A per-display **HiDPI smooth scaling** section installs a dense scaled-mode ladder as a
  display override, so macOS offers scaled resolutions down to half the native size (issue
  #27).
- DDC/CI replies are validated before their numbers are used, reads are quarantined after
  repeated failures, and reads are cached for five seconds and paced like writes (issue
  #25).

### Changed
- A write whose reply is lost now says so instead of inviting a blind retry: the CLI reports
  "the command may have applied", names the read-back command and exits 75 (issue #31).
- The software boost no longer overwrites the display's own picture settings; it composes into
  the user's filter instead (issue #29).
- `fbdcli auth-token` no longer prints the API token to stdout; `--reveal` prints it
  explicitly, because the token grants full control of the user's displays, and the local
  API token comparison now has one implementation (issue #32).
- Enabling or disabling a display and switching its mode now pause DDC traffic and wait for the
  transactions in flight, which used to freeze the whole Mac (issue #25).

### Fixed
- The HTTP server parsed every request's headers twice, once per received TCP segment, and a
  DDC/CI write left a stale cached read behind; the header block is now parsed once per
  request.

### Documentation
- ADR 0005 records why the HiDPI override is a *command model* rather than a script: the
  ladder, the path and the idempotency check are pure, and only the executor knows about
  privilege escalation (issue #23, issue #27).
- `docs/ddc-equivalence.md` audits FBD's DDC/CI transport against didriksg/Crisp v1.7.1
  component by component; each divergence is either aligned or recorded with the reason the
  equivalence still holds, so the claim is code-verified equivalence, never hardware
  verification.
- `scripts/ddc-smoke.sh` is a non-destructive DDC/CI smoke harness: it enumerates the
  displays, parses the EDID and capabilities string, reads brightness, contrast and volume,
  and can write-test each one with the original value restored.

## [2.0.0] - 2026-10-16

### Changed
- Settings is redesigned in the popover's design language: glass cards, round icon chips, a
  large page title, and a sidebar with a tinted icon per page. Every page uses the new
  `SettingsPane` / `SettingsGroup` containers.

### Fixed
- Opening a display's page in the popover paused for a beat before the slide started: the
  whole page was laid out in the transition's first frame. The mode lists now appear first
  and the heavier sections follow once the slide ends.

## [1.8.1] - 2026-10-16

### Fixed
- External displays on Apple Silicon were never matched to their AV service, so DDC/CI and
  EDID reads could not work on any monitor; the service is now paired by EDID UUID and
  registry order.
- `IOAVServiceCreateWithService` and `IOAVServiceCopyEDID` were declared with the wrong
  signatures (missing allocator; missing out-parameter) and are now declared correctly.
- A display that has an AV service but never answers DDC/CI (most TVs) is no longer offered DDC
  controls after its first refresh.
- `fbdcli config group-sync` exited before its debounced brightness writes landed, so it
  reported success without changing anything; it now waits for them, and `fbdcli ddc-test`
  reports the AV service and the DDC/CI reply separately.

### Changed
- Scaled modes the system reports without the HiDPI flag (seen on an LG TV, "looks like
  1920x1080" on a 4K backing) are now treated as HiDPI, and the CLI labels non-HiDPI modes
  `lodpi` instead of `sdr`.
- EDID overrides are disabled on Apple Silicon: `IOAVServiceSetVirtualEDIDMode` takes a
  32-bit mode plus raw EDID bytes and its mode values are undocumented, so applying an
  override now fails instead of guessing.

## [1.8.0] - 2026-10-16

### Changed
- **Redesigned the menu-bar panel (Control Center style, Liquid Glass on macOS 26+);
  Settings now opens in its own window.** The panel is a borderless popover sized to its
  content: each display's brightness (and DDC volume) slider, quick toggles for Dark Mode,
  Night Shift, True Tone and Keep Awake, presets, and rows for virtual screens and display
  groups. Every label is localised in English, Simplified and Traditional Chinese, and CI
  and release builds now require Xcode 26+.

### Added
- **Named display presets: a display's whole configuration saved under a name, with an
  icon.** A preset records the mode, refresh rate, brightness, the XDR preset, HDR mode,
  rotation and the colour profile, and is reachable from the CLI, Settings, the panel and
  Shortcuts.
- **The pointer can cross between displays whose edges do not line up.** macOS stops the
  pointer at an edge no other display covers, so a short display beside a tall one traps it
  in the gap; `fbdcli layout edge-crossing` carries it over instead.

### Fixed
- **DDC/CI now uses the framing Apple Silicon monitors expect** (5-argument `IOAVService` I2C
  calls, `0x84 0x03` / `0x82 0x01` packets, XOR checksum), matching the reference
  implementation; brightness, contrast, volume, input and mute over DDC are rewritten accordingly,
  not yet verified on hardware (#7).
- Mute media key no longer only unmutes; DDC slider drags send the latest value instead of
  queueing every step; the DDC service cache is refreshed on display changes; EDID product
  code and serial are read little-endian.
- XDR upscaling above the hardware ceiling falls back to the software boost when the
  native preset write is refused (macOS 27), and ending a boost no longer removes the dim or
  rounded-corner overlays.
- A built-in display disabled by FBD, and a lock-dimmed brightness, are restored after a crash or
  quit.
- `fbdcli`: a bad token or timeout is an error instead of silently driving the hardware
  directly; `--direct` inside automation payloads is preserved; `help` lists `enable` on its
  own line; zsh completion covers every command.
- **Creating a virtual screen no longer crashes FBD.** The SkyLight calls that build a
  virtual display were handed pointers to temporaries that Swift released as soon as the
  pointer was taken; the objects are now kept alive for the whole call.

### Security
- The HTTP API token and LG TV pairing key moved from preferences to the Keychain (migrated on
  first run), so `fbdcli` may show a one-time Keychain prompt.
- The local API rejects browser requests (non-loopback `Host` or any `Origin`), sends no
  CORS headers, caps concurrent connections and no longer falls back to a guessable token,
  and `FBD_DISPLAY_NAME` is sanitised before it reaches automation scripts.

## [1.7.0] - 2026-10-14

BetterDisplay-parity work agreed at the Phase 3 gate. The scope, the evidence behind it and the
deliberate exclusions are recorded in the BetterDisplay-parity scope notes.

### Added
- **DPCD support.** `fbdcli dpcd <display>` reads the sink's configuration block over AUX,
  and only the read path is declared, so a wrong write cannot wedge the attached display;
  `fbdcli report --dpcd <hex>` decodes a dump you supply.
- **The HUD can use the system's glass.** The OS's glass (macOS 26+) is a third HUD
  background; the default is untouched, so an untouched install keeps the look it has always
  had.
- **FBD speaks 简体中文 and 繁體中文.** Three localisation files beside the icon are copied into the
  bundle by `make app` and cover the panel, the Settings pages and the filters/automation
  views. Settings titles were invisible to them, because the UI passed them as plain strings,
  and now resolve.
- **The DDC input menu marks the input in effect.** Reading the input source was a
  blocking read, so the menu refused to guess; it now rides in the same batched read as
  contrast/volume/mute and checkmarks the current input.
- **A Dark Mode toggle, completing Night Shift + True Tone.** `fbdcli dark-mode [on|off]`
  and a toggle in Settings; it degrades to "unavailable" where the system's symbols are
  missing.
- **Resolution handling, reshaped.** The panel offered every mode inline — 132 of them on
  this machine — while reaching one through the ⋯ submenu cost three clicks; it now shows
  one row per logical size at the current aspect ratio, HiDPI preferred, with **Show all N
  modes**, a filterable mode list and a deduplicated refresh-rate list.
- **Resolution favourites.** Five recall slots per display, applied from the Displays page
  or `fbdcli config favourite`; a slot is recalled exactly, and a missing one reports itself
  unavailable rather than applying a wrong mode.
- **Configuration protection covers eight properties.** Resolution, refresh rate, preset,
  HDR mode, main status, brightness, rotation and the colour profile, each selectable per
  display. Rotation and the colour profile cannot be read, so they are restored from the
  value FBD last applied.
- **`fbdcli config identity` and `config transfer`.** Which key a display's stored
  settings are filed under is now a choice, and one display's settings can be copied onto
  another; the default reproduces the historical key byte for byte.
- **A saved network-device registry, and a device can be attached to a display.** `fbdcli config
  device list|add|remove` manages the devices and `fbdcli tv <name> …` addresses one by name; an
  attached device follows that display's volume when the brightness/volume keys drive it.
- **Manual controls and a notification action for automation.** A rule can be scoped to
  `manual` — a control you invoke yourself — and a `notify` action posts a user notification
  in-process.
- **`fbdcli report [file]` — an exportable display report.** A paste-ready block per display
  (identity, kind, geometry, mode, refresh rates, control paths, brightness, XDR/HDR state) under
  a header carrying the FBD and macOS versions.
- **The HTTP API and Shortcuts cover the new settings.** `GET /api/config` reports lock dim,
  the keyboard control target, the brightness model and configuration protection, `POST
  /api/config/…` adds the matching writes, and three Shortcuts actions make them scriptable.
- **`fbdcli config` completed.** One command for the settings above, running against the
  shared defaults with no second write path, and refusing unknown names, targets and on/off
  words.
- **Display-group synchronisation and activation policy.** Groups gained an enable flag, one of
  five activation policies, sync member filters and an optional nits-matching mode, managed on
  the new Groups page and via `fbdcli config group-policy|group-enabled`.
- **Startup safe mode and lock dim.** Holding ⇧ Shift at launch (or `FBD_SAFE_MODE=1`) skips
  stored EDID overrides and configuration-protection restore for the session; lock dim
  darkens to a chosen level while the screen is locked and restores on unlock.
- **Keyboard control target and connection management.** The brightness and volume keys can act on
  the screen under the pointer, the focused screen, every suitable screen, or the display matching
  the current audio device; ordered connect/disconnect/swap steps run through the guarded
  disconnect path, never disabling the built-in display without the explicit override.
- **`fbdcli ambient-light <display> [on|off]`.** Reads or sets the Apple panel's
  ambient-light auto-brightness, which was reachable from the panel's More menu but had no
  CLI surface.
- **The status item's icon is now a choice, and it can hide itself.** A curated set of SF
  Symbols is offered, and hiding the icon while no external display is attached is refused
  unless a Dock icon is enabled.
- **A sidebar Settings layout, with panel shortcuts.** Settings was a two-tab form; it is
  now a sidebar of `Displays` · `Groups` · `Application` · `Menu` · `Keyboard` · `About`, and the
  panel grew its own shortcuts: ⌘ for the settings gear, ⌘⇧V (Virtual Screens), ⌘⇧G (Groups),
  ⌘⇧P (PiP), ⌘U (Check for Updates) and ⌘Q (Quit FBD).
- **A virtual screen can be associated with real displays, so an arrangement is recalled
  when it attaches.** `fbdcli config vscreen associate` records it by display identity, and
  recall fails closed if an associated display is absent.
- **GUI scale matching.** The panel's physical size is now exposed, so the scale it
  implies can be matched to a reference; `fbdcli config uiscale` reports rather than
  applies, and fails closed when no mode is close enough.
- **Keep the Mac awake, and run several PiP windows at once.** A toggle in Settings → Menu →
  System holds a no-display-sleep assertion while FBD runs; capture sessions are keyed by
  their source, so a second display's PiP opens a second window.

### Changed
- **The panel is one surface now: rows are bands, not cards.** The rounded cards that
  floated inside the panel now are full-width bands separated by hairlines, and the chrome
  uses a flat shade instead of stacking a second material on the glass.
- **The menu-bar panel is flattened.** Each display is now one compact row — icon, name,
  capability badges, current mode, the options menu and the power button — and Filters,
  DDC/CI and the resolution/XDR sections moved behind a single **More controls** disclosure.
- **The brightness/volume HUD is configurable.** Position, a continuous or a segmented bar, a dark
  HUD or one that follows the system appearance, a shadow toggle and a corner-radius slider; the
  defaults reproduce the previous appearance exactly.
- **Dock visibility rules.** A menu-bar app is an accessory by default; it can now be given
  a permanent Dock icon, or a brief one at launch.

### Fixed
- **"Prefer hardware brightness" and the curve's dimming zone now work, and a brightness
  read now agrees with the screen.** Software brightness was applied as an overlay but
  neither tracked nor reported, so a read returned the backlight value while the screen
  showed something dimmer; the dim is now tracked per display, and a request brighter than
  the backlight falls back to the hardware.
- **Four brightness-model sliders shaped nothing; two of them do now.** The upscale maximum
  and the dimming switchover take effect when the profile carries them.
- **The startup control-value policy works now.** The brightness is now recorded per display
  and launch reads it back, re-writes it or leaves the device alone as asked.
- **"Allow unsafe modes" did nothing; now it does.** The setting was written by the Settings page
  and read by nobody; the offered list now runs through the mode filter in the panel, the
  per-display sections and `fbdcli modes`.
- **Settings → Back discarded a resized panel.** Going back restored a hard-coded 460×650; the
  size the panel had when Settings opened is now remembered and restored.

### Documentation
- Two sibling projects, FreeDisplay and Crisp, were reviewed for what FBD lacks. The
  capability comparison and the licences are recorded in the attribution notes in
  `ACKNOWLEDGMENTS.md`: FBD is ahead on automation, network devices, streaming and EDID
  override, and behind on named presets and localisation.

## [1.6.0] — 2026-10-04

### Added
- **A feedback layer.** There was no loading or error state anywhere in the UI: an inline
  working/failed/succeeded line with a single combined VoiceOver announcement, a notice
  surface for menu-initiated actions, and a spinner in the DDC panel while it probes.
- **DDC inputs are offered by name.** When a display reports which inputs it has, the panel offers
  those by name — "HDMI 1", "DisplayPort 2" — and shows anything outside the standard table as
  `Input 0xNN` rather than attaching a plausible-looking wrong label.
- Two shared UI primitives: the display-card surface, previously copied byte-identically
  into four views, and a 28pt hit target for icon-only controls, applied to seven of them.

### Changed
- **A design-review pass over the whole UI**, driven by an Impeccable critique scored
  against Nielsen's heuristics, and a motion pass: the theme's 280ms bouncing spring was
  renamed to match what it now does.

### Fixed
- **`Read capabilities` froze the UI while it ran.** The DDC probe blocks and its only
  caller was on the main actor, so the main thread stalled for the whole probe; the read now
  runs on the per-display queue.
- **Controls that silently did nothing now say so.** The DDC panel's input "Apply"
  returned early on an invalid value with no feedback, and rotation and mirror/unmirror
  results were discarded, so a refused action looked dead; both now surface.
- **`Configuration Protection` misrepresented its own scope.** It was a per-display menu
  toggle over one *global* flag, so enabling it saved only the display whose menu it was
  flipped from; it lives in Settings now and snapshots every online display.
- **`Show in Settings` promised navigation it never performed.** It posted no payload and
  landed on the Overview page showing nothing about the display; it now opens the
  Per-Display tab and scrolls to that display.
- **`Mirror Display` opened empty on a single-display Mac**, because its targets are other
  *online* displays; it is disabled with a reason instead.
- **A display with no DDC/CI now says so** rather than silently omitting the panel, which read as
  a bug rather than as an absent capability.
- **The arrangement grid's display names were unreadable in light mode** — 9pt white on a
  25%-opacity accent fill, roughly 1.5:1 — and non-dragging tiles now use `.primary`, which
  adapts to the appearance.
- **`release.yml` looked for the wrong CHANGELOG heading.** It searched for the tag form
  while headings are written without the `v`, so every release after 1.4.0 would have
  shipped with empty release notes; the search is now anchored to the start of a line.
- **Four controls had no accessible name.** The automation rule toggle and its three
  pickers were built with an empty label that was hidden visually but still exposed, so
  VoiceOver had nothing to announce.
- **Reduce Motion was bypassed in two places.** The footer's expanders animated regardless
  of the setting, and a conditional had identical branches, so it did nothing while
  appearing to handle the setting.

## [1.5.0] — 2026-10-03

### Fixed
- **Built-in display disconnect is refused on base-M3 MacBooks.** Apple repurposed the
  built-in panel's connection for clamshell two-display support on those Macs, so a
  soft-disconnected built-in display may not come back without a reboot. (BetterDisplay
  ships the same guard — waydabber/BetterDisplay#4723.)

### Added
- **Full-screen filters gained sharpening, geometry and custom 3D LUTs** (BetterDisplay 5
  parity). The filter now carries sharpening, zoom/pan and an optional `.cube` LUT path, all
  clamped, and the overlay applies them in one pass: a 4-tap unsharp mask, zoom/pan in the
  vertex transform and a 3D texture sampled after the colour maths.
- `fbdcli filter` gained `--sharpness`, `--radius`, `--zoom`, `--pan x y` and `--lut path`,
  with the same optional fields accepted by the HTTP `filter` route, and `.cube` parsing is
  strict, so a malformed file yields a specific error.
- **PiP can now capture a window or an application**, not just a display (BetterDisplay 5's
  "PiP for individual windows"). The capture source maps onto ScreenCaptureKit's three filter
  constructors, a window is captured at its physical pixel size rather than upscaled, and an
  application composites all of its windows.
- **Local streaming** — `fbdcli stream <source-display-id> <target-display-id>` redirects
  one display's contents onto another, full-screen, using the same capture pipeline as PiP;
  streaming a display onto itself is rejected up front.
- **Run a shell script or open a URL when a display connects/disconnects, or when the system
  sleeps/wakes** — BetterDisplay's per-display commands. This is the one place FBD executes
  arbitrary code, so a rule exists only because someone created one.
- Every automation action is time-limited, rate-limited so a burst of topology events cannot
  run the same script several times and executed on a serial queue so an event storm cannot
  stampede the machine; `fbdcli automation` manages the rules.

### Changed
- One filter parser now serves both `fbdcli filter` and the routed HTTP plan, so the two can no
  longer drift.

## [1.4.0] — 2026-08-04

### Added
- **Per-Display control page** — the per-display settings tab grew into a full control page,
  with each display's own sections rather than one shared list, and a drag-to-arrange grid
  sets the layout by dragging displays directly.
- Two ADRs recording those decisions: `0001-no-virtual-screen-software-brightness` and
  `0002-display-arrangement-via-public-cg-api`, plus engineering notes on the domain model, the
  issue tracker and triage labels.

## [1.3.3] — 2026-08-04

### Fixed
- **Color-temperature filter was inverted** — dragging toward "Warm" made the screen bluer; the
  shader's r/b math is swapped.
- **The HTTP API's default port was 0 (ephemeral)** despite the README promising 8765 — the
  default is now 8765 — and media-key interception was silently ON, now opt-in (default off) and
  documented.
- **The DDC contrast/volume/mute UI was send-only** (always showed 50%); the panel now reads the
  monitor's real values back.
- **Dead code removed**: IOMobileFramebufferAPI (an unimplemented "XDR direct" path the README
  claimed), the "Stream Display" menu twin of Picture-in-Picture, the FBDIntents placeholder.
- **The brightness read now agrees with the screen.** One deep brightness module replaces
  the three places that duplicated the nits-ceiling maths, so the upscale-state invariant
  holds on every path, and the settings-persistence bypass is closed.

### Changed
- Several internal consolidations: the LG webOS and Samsung Tizen controllers now share one
  WebSocket base, the routed CLI vocabulary has a single source, the display row view is
  split into per-capability child views, and the CLI's second DDC stack was deleted.
- The local API moved behind a single seam — the whole surface is now testable with a
  fake, the app-side entry point shrank from ~120 lines to a thin wrapper, and virtual
  displays route through the same seam.
- README documents the `fbd://open` URL scheme and the media-keys opt-in, and `CONTEXT.md` was
  added as the domain glossary.

## [1.3.2] — 2026-08-03

### Changed
- **PiP window is now closable and resizable**: the window gained a standard title bar with a
  native close button and resize edges, and closing tears the session down.
- **"Video Filter Window" renamed to "PiP"** everywhere — the old name was confusing since it
  opens a picture-in-picture window.
- **UI simplification sweep** (feedback: "confusing / overengineered / footer buttons do
  nothing"): the per-card quick-toggles row was removed (HiDPI and Auto Brightness moved
  into the display's options menu, the dead Notch toggle was removed entirely).
- **Image Adjustments moved out of the options menu into a card "Filters" disclosure** — sliders
  inside SwiftUI menus are fragile; the disclosure matches the card's other sections.
- **Adaptive panel-height experiment reverted**: fitting the panel to the SwiftUI content on
  display changes fought the hosting controller, so the panel stays at its fixed sizing with
  the pinned footer.

### Fixed
- **App crashed when a second virtual screen was created** (and at launch when an
  autoConnect config reconnected after one was already active): the framework's error object
  was over-released at the autorelease-pool drain. Note: creating more than one virtual
  display now fails gracefully on this macOS 27.

## [1.3.1] — 2026-08-03

### Fixed
- **Tools footer wrapped into a multi-line mess at 460pt**: collapsed into a single compact
  "Tools" menu (Displays / Virtual Screens / Groups / Video Filter Window / System Colors / Check
  for Updates / Quit) plus one quick Video Filter Window button.
- **Each "Video Filter Window" click spawned a new window** (rows and footer each owned
  their own capture controller): the controller is now shared and stops synchronously.

## [1.3.0] — 2026-08-03

### Added
- **Full-screen Image Adjustments** (the last UI gap): per-display software filter with live
  contrast / saturation / gamma / color-temperature sliders and an invert toggle, rendered by the
  same overlay pipeline as the XDR boost, reachable from the CLI and the routed HTTP API.
- **Screen Rotation** (0/90/180/270), wired into the options submenu and `fbdcli rotate`;
  the system call returns an error for the built-in display on this macOS, so it fails
  gracefully, and external-display verification is still pending.
- **Per-display options menu** (ellipsis in each display card): Display Mode, Refresh Rate,
  Color Mode, Apple Display Preset, Mirror Display, Stream Display and Picture in Picture, Image
  Adjustments, Move Display, Screen Rotation (honestly disabled — unsupported), Configuration
  Protection and Manage Display.
- **Quick-controls row per display**: HiDPI toggle (same-size mode variant), Auto Brightness
  toggle (hardware ambient-light compensation, hidden when unsupported) and Notch toggle
  (disabled — unsupported).
- **Tools footer**: Displays And Virtual Screens (scroll-to menu), Groups, Video Filter Window
  (opens a real PiP stream), System Colors, Check for Updates, Quit FBD.
- **Settings tabs**: Overview / Per-Display segmented control, where the tab lists each
  display with its mode, brightness and connect/disconnect controls.
- HTTP API: POST /api/displays/<id>/rotate and /filter (+ off).

### Changed
- `DisplayController`: ambient-light compensation passthroughs and `setAsMainDisplay`
  (CGConfigureDisplayOrigin to (0,0)).

## [1.2.1] — 2026-08-03

### Fixed
- **Software XDR boost rendered the screen out of focus**: the capture used the display's
  point size, so the overlay redrew a 2x display at half resolution; the capture now uses
  the physical pixel resolution.

## [1.2.0] — 2026-08-03

### Added
- AppIntents bridge so the Shortcuts actions from the `FBDIntents` module are discoverable by
  macOS (previously compiled but unreachable from Shortcuts), plus `fbdcli list --json` and
  `fbdcli info <id> --json` machine-readable output and zsh completion for every command.
- Media-key interception status surfacing: the Settings panel shows a "Media keys
  unavailable" hint when Accessibility permission is missing or revoked, and the event tap
  auto-re-enables after system suspension.
- Right-click status-item menu (Show FBD / Settings… / Quit FBD); `fbdcli settings` masked
  settings dump for bug reports; `GET /api/health` unauthenticated endpoint; live HTTP
  server reconciliation, so `fbdcli http on/off` applies without an app restart.
- `make bump-version VERSION=x.y.z [BUILD=n]` release helper, and a tag-triggered release
  workflow that signs, notarizes and publishes when the secrets are configured; the XDR
  fallback decision chain is now a pure, tested layer shared by the slider and the `xdr`
  command.

### Changed
- **UI overhaul** — premium floating-glass panel (Control Center-style):
  - A design system with semantic system colors, shared spacing/radii/motion tokens and full
    dark/light adaptation.
  - Frosted-glass panel background with rounded cards for display rows, virtual screens and groups.
  - Custom slider — gradient fill, floating thumb, hover/active micro-animations, an XDR "boost
    zone" divider; keyboard arrows and VoiceOver adjustable-action support.
  - Brightness control now shows a live nits estimate on XDR displays and a hardware→XDR zone
    marker; badges distinguish Built-in / External (DDC) / Virtual / XDR displays.
  - Settings regrouped into icon-labeled sections; Reduced Motion respected throughout.
  - **Top-bar overlap fixes**: a reserved frosted titlebar strip so content never slides under the
    traffic lights, and the main header is a fixed elevated bar instead of floating. Settings got
    its own fixed header bar with a **Back** button.
- UI: the status-item popover is now a floating panel (title bar + close button, resizable, frame
  autosave, Escape/⌘W close, and a natural back button from Settings).
- CLI parsing moved to a testable library and HTTP request routing (auth, method, path, body
  validation) moved into the core, so the app only executes typed routes.
- DDC: VCP reads retry, the settle time is configurable, and capabilities replies must
  contain a complete value group; `GET /api/health` now reports the displays with a live
  software-boost session, and the app icon is a generated squircle.

### Fixed
- **The XDR software boost works again on write-protected systems.** The explicit `xdr <id>
  <nits>` command always chose the native preset path when the display was XDR-capable; the
  software boost is now the fallback, and it defaults ON.
- **The boost overlay composited and cleaned up correctly.** The renderer presented Metal
  drawables manually from the capture queue on a paused view, which renders nothing on this
  system, so it switched to the standard draw pattern.
- **The panel read its brightness at launch, and its chrome lined up.** Nothing performed an
  initial brightness read, so the panel showed "Brightness unavailable" until a write
  happened.
- **Settings toggles no longer turn gray after the panel loses focus.** The panel is a
  non-activating panel that rarely holds key status, so SwiftUI rendered every control in
  the gray "inactive" variant; the panel root now forces the active control state.
- **The combined slider stops an active overlay boost** when it drops below the ceiling,
  which previously left the screen brightened; the overlay itself requires **Screen
  Recording** permission.
- Several controller and CLI fixes: routed `virtual destroy` now resolves a name to its
  persisted id, routed `virtual create` honours the `isHDR` flag, and virtual-display
  detection uses a persisted registry.
- **EDID overrides are validated before they can reach the display.** Size, header and
  base-block checksum are checked at the CLI, controller and persistence gates, so garbage
  no longer reaches the display registry or the auto-apply store.
- Several server and app fixes: a declared `Content-Length` above 1 MB is rejected with 413
  before buffering, `Expect: 100-continue` is acknowledged so curl/URLSession clients no
  longer hang, the colour-profile controller no longer force-unwraps its UUID (a crash when
  a display disconnects mid-flight).
- SIGTERM now routes through the app's normal termination path so AppKit cleanup runs on
  `kill`, the PiP controller is shared between start and stop, and mode-apply failures now
  exit non-zero instead of reporting success.

## [0.1.0] — 2026-07-31 (scaffolding)

### Added
- Initial SwiftPM structure: FBDCore library, menu-bar app, `fbdcli`, `FBDIntents`,
  `CPrivateAPI`.
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
