# Plan — post-1.4.0 (2026-08)

Status: current.

1. **Signed distribution** (P0, user-gated): Developer ID cert → signing +
   notarization workflow → Sparkle auto-update installs without the
   Gatekeeper warning. Exact steps in RELEASING.md.
2. **Hardware verification** (user-gated): rotation on an external display,
   two-display drag arrangement, DDC-monitor checklist.
3. **Stability**: re-run the full live CLI matrix after each macOS update;
   dependency-drift watch (Sparkle, actions/*).

Done in 1.4.0: Per-Display control page, drag-to-arrange grid, architecture
seams (CombinedBrightness, HTTPExecutor, virtual seam), settings-bypass fix.
