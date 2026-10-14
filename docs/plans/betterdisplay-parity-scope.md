# Scope note — FBD ⇄ BetterDisplay feature-parity + UI-parity

Date: 2026-10-14 · Branch: `feat/betterdisplay-parity` · Base: `256ec2f`
Plan: `~/Downloads/FBD-betterdisplay-parity-plan.md`

## What this work is

Two goals, in order:

1. **Feature parity** — establish, from evidence, which BetterDisplay features FBD lacks, and
   implement the ones worth implementing behind FBD's existing controller seams, with tests.
2. **UI/IA parity (inspired, not cloned)** — rework FBD's information architecture so its
   grouping and depth of control feel familiar to a BetterDisplay user, using FBD's own
   naming, SF Symbols and design system.

## Phases (as planned, executed in order)

| Phase | Deliverable | Gate |
|---|---|---|
| 0 | Baseline + FBD UI inventory + this scope note | build/test/app/ui-smoke green |
| 1 | `docs/plans/betterdisplay-feature-inventory.md` | every row cites its evidence source |
| 2 | `docs/plans/fbd-feature-inventory.md` | every README claim marked verified / partial / absent |
| 3 | `docs/plans/fbd-gap-matrix.md` | **decision point — user sees the matrix before any implementation** |
| 4 | the agreed gaps implemented | per-gap: unit tests, CLI round-trip, UI control, ledger + changelog |
| 5 | UI/IA revamp + before/after screenshots | `make ui-smoke` still green |

## Boundaries (non-negotiable)

**Legal / ethics.** BetterDisplay is a paid app the user licenses; FBD is public and MIT.

- No BetterDisplay code, assets, icons, strings, nibs or disassembly output is copied into FBD.
  Behaviour and information architecture are learned from it; FBD reimplements in its own idiom.
- No localised strings are copied. FBD wording matches *meaning*, never text.
- **`/Applications/BetterDisplay.app` is read-only in this task.** Not patched, not re-signed,
  not modified. (It already carries a 2-byte patch from earlier, unrelated work — not added to.)
- No BetterDisplay-derived material is redistributed.

**FBD repo rules** (from the repo's own `AGENTS.md`):

- Private C symbols: declared in `Sources/CPrivateAPI/include/fbd_private_api.h`, wrapped in
  `Sources/FBDCore/PrivateAPI/`, throwing + `os_log` + graceful degradation. Never called inline.
  Private ObjC classes via `NSClassFromString` + runtime messaging only.
- Never crash on a missing private API — degrade and say so in the UI.
- Every control path goes through its controller seam (`DisplayControlling`,
  `CombinedBrightness`, `VirtualScreenController`, …).
- All persisted settings go through `Settings.defaults` — no second write path.
- Changing a controller's public API means updating **every** caller (UI, CLI, HTTP executor,
  tests).
- Every private API entry is recorded in `docs/PRIVATE_APIS.md` with verification status.
- DDC is guarded by `IOAVServiceAPI.isAppleSilicon`; warn under Rosetta.
- Commits small, one logical change, descriptive. Work on a branch. **No force-push. No push
  without being asked.**
- **HTTP/URL surfaces stay token-gated.** `fbd://brightness/<id>/<value>` requires
  `?token=<httpAPIToken>`. This gate is never loosened for convenience — pass the token.

## Deliberately out of scope

1. **Anything requiring a licence server or paid tier.** BetterDisplay's *Pro* badge marks a
   large slice of its surface (image adjustments, PiP/streaming, protection, connection modes…).
   Those features are in scope as *behaviour to reach parity with*; BetterDisplay's
   *licensing machinery* is not, and nothing that depends on a licence check, a Paddle/entitlement
   file, or a remote validation service will be ported or imitated.
2. **Anything the dev machine cannot verify.** There is only a built-in display connected (no
   DDC-capable external monitor) and macOS 27 is the only OS available. So:
   - DDC/CI external-display behaviour stays *wired but hardware-unverified* (as the repo's
     backlog already records);
   - the `CGVirtualDisplay` path (macOS 13–15 only) stays *implemented but unverified here*;
   - rotation on an external display stays *user-gated*.
   These are recorded as gaps and **not** claimed as verified work.
3. **Modifying BetterDisplay.** Also out of scope: using its patched state (the existing licence
   bypass in the installed binary) as evidence about its real behaviour. Where a comparison
   depends on a Pro gate, the *licence-gated* nature is noted rather than worked around.
4. **Reworking FBD's private-API surface for its own sake.** New private symbols only where a
   chosen feature actually needs one.

## Decisions confirmed at the Phase 3 gate (2026-10-14)

The user reviewed `docs/plans/fbd-gap-matrix.md` and decided:

1. **Phase 4 scope = the recommended top-8.** Implement, behind their existing seams with tests:
   1. per-property configuration protection (matrix #1)
   2. group synchronisation + activation policy (#2, #3)
   3. startup safe mode (#7)
   4. resolution favourites + mode-list breadth + refresh/VRR list (#4, #5, #6)
   5. device-control policies + editable nits ranges + combined-curve switchover points (#9, #10)
   6. dim on screen saver / lock (#8)
   7. connection-management extras + auto-brightness CLI surface (#11, #12)
   8. keyboard-control target (#15)
   Everything else in the matrix is **deferred**, recorded, and not implemented in this pass —
   including Tier 3 #22/#23/#27, which are blocked on private APIs FBD has not identified.
2. **Phase 5 (UI/IA revamp) runs after Phase 4 in this same session**, in the plan's phase order.
3. **BetterDisplay reference screenshots stay out of the repository — permanently.** They live at
   `~/Downloads/bd_poc/bd-ui-reference/` and are referenced by path only. They must never be
   committed, pushed, or otherwise leave this machine (no GitHub, no release artefacts). FBD's own
   before/after screenshots may be committed under `docs/plans/fbd-ui-before/` and
   `docs/plans/fbd-ui-after/`.

This resolves the open question below in favour of the safer reading: §2's
"do not redistribute BetterDisplay-derived material" wins over §5's suggested in-repo path.

