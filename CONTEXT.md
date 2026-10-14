# FBD — Domain glossary (CONTEXT.md)

Terms the codebase and its modules use. Architecture reviews and design work
refer to these names, not file paths.

- **Display** — a monitor or virtual screen FBD manages (built-in, DDC
  external, or virtual). Identified by a `CGDirectDisplayID`.
- **Brightness** — the 0…1 slider value; maps linearly to **nits**.
- **Combined brightness** — the unified brightness curve: hardware writes
  below the **hardware ceiling**, XDR upscaling above it.
- **Hardware ceiling** (`hardwareMaxNits`) — the display's native maximum
  nits without any upscaling.
- **XDR upscaling** — raising brightness above the hardware ceiling; either
  the **native** path (preset rewrite) or the **software boost** overlay.
- **Software boost** — the full-screen overlay fallback used when native
  preset writes are unavailable (e.g. write-protected slots on macOS 27).
- **Upscale state** — a display's current `isXDRUpscaled` flag + target
  nits. Invariant: it must mirror what is actually on screen on every path.
- **Combined route** — the plan decision (hardware / native upscale /
  software boost / fail) for a brightness request.
- **Arrangement** — the desktop positions of the connected displays; edited
  in the Settings → Per-Display grid and committed via the public
  CoreGraphics configuration API.
- **Virtual screen** — a display created by FBD via the OS virtual-display
  framework; configured at creation (size/HDR/Hz) and not resizable or
  dimmable at runtime (see ADR-0001).
- **HUD** (`OSDStyle`) — the transient brightness/volume readout. Its position,
  bar style, background, shadow and corner radius are user settings whose
  defaults reproduce the pre-settings look.
- **Protected property** (`ProtectedProperties`) — one of the configuration values
  a display's saved state may restore: resolution, refresh rate, brightness,
  preset, HDR mode, main status.
- **Activation policy** (`GroupActivationPolicy`) — when a display group's sync
  applies, decided by which of its members are present.
- **Manual control** — an automation rule whose event is `manual`: invoked by the
  user, never by the system. ON and OFF are two of them, and a rule that prints
  its state is a third.
- **Notification action** — an automation rule that posts a user notification. It
  runs in-process, unlike a shell or URL action, and only the app can post one.
- **Attachment** (`NetworkDeviceAttachment`) — a saved network device bound to a
  display **identity**, so the device follows that display's volume.
