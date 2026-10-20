# Acknowledgments

FBD is an independent implementation. This file records where the ideas came
from, so the credit is explicit — none of the code, strings or assets of the
projects below were copied.

## didriksg/Crisp — MIT, © 2026 Didrik Galteland

[Crisp](https://github.com/didriksg/Crisp) (a FreeDisplay fork) is the closest
cousin of this project: same platform, same private display APIs, same mission
of a free alternative to the commercial app in this space. Four techniques in
FBD were designed against Crisp's implementation and reimplemented from scratch:

| FBD | what was taken from the design |
|---|---|
| `docs/ddc-equivalence.md` | the shape of a DDC transport that validates every reply, caches reads, quarantines a dead channel and holds the bus across a topology change |
| `Sources/FBDCore/Controllers/HiDPILadder.swift` | the idea of a dense scaled-mode ladder (native size stepped down in 16-point units, aspect held, floor at half) |
| `Sources/FBDCore/Controllers/BrightnessFloorBlend.swift` | the split of a brightness slider into a hardware part and a software part at a threshold, so the slider's bottom is reachable |
| `Sources/fbdcli-parser/AgentSkill.swift` | the doctrine of an agent-facing CLI contract: a write that was not confirmed is not a failed write |

The component-by-component comparison against Crisp v1.7.1 is in
[`docs/ddc-equivalence.md`](docs/ddc-equivalence.md); it claims **code-verified
equivalence**, never hardware verification.

## huberdf/FreeDisplay — MIT (declared in the README; the repository ships no licence file)

Looked at for its capability list. Nothing was taken from it.

## BetterDisplay — proprietary

Read for **observable behaviour only**: which features a comparable app has,
what it says about them, and how the operating system behaves. No code, string
or asset was copied. FBD is not affiliated with BetterDisplay or its author.

## The rule

Where a licence would permit reuse, FBD still reimplements. Reading a
competitor's behaviour is fair; copying its implementation is not, and the
line between the two is why the private-API ledger
([`docs/PRIVATE_APIS.md`](docs/PRIVATE_APIS.md)) records every private symbol
FBD resolves at runtime, how it was verified, and on which macOS versions.
