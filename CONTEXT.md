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
