# 5. The HiDPI override is a command model, not a script

Date: 2026-10-20

## Status

Accepted.

## Context

Adding display overrides (the `scale-resolutions` list macOS reads when it
builds the HiDPI mode ladder) means writing into
`/Library/Displays/Contents/Resources/.../Overrides/...`, which needs
administrator rights.

Two ways to get them:

- a privileged helper (a login item or a `SMJobBless`/`SMAppService` job),
  which can ask for Touch ID and never shows a password prompt;
- a one-shot privileged execution — `osascript` running
  `do shell script "…" with administrator privileges` — which shows the
  standard administrator prompt.

The helper is the better long-term answer, but it cannot ship in this
release: it needs a Developer ID certificate and a signed, notarized
privileged helper, which is blocked on its own issue (#6). The HiDPI ladder
itself does not need to wait for that.

There is a second reason to keep the two apart. Writing an administrator
prompt by hand means building a shell command from data: the display's
vendor and product identifiers, the override path and the ladder itself. A
shell command is a language, and a value that reaches it unescaped is a
command injection. The interesting part of this feature — the ladder, the
path derivation, the idempotency check — has nothing to do with privilege
escalation and should be testable without it.

## Decision

Split the feature in two.

- **The command model** (`HiDPIOverrideCommand`, `HiDPILadder`,
  `HiDPIOverrideService`) knows *what* has to happen: which ladder to write,
  which path it goes to, whether the file on disk already says that, and the
  exact command that performs the write. It is pure, it is unit-tested, and
  it never touches the machine.
- **The executor** (`PrivilegedCommandExecuting`) knows *how* the command is
  run with administrator rights. Today that is the AppleScript one-shot.
  Tomorrow it can be the Touch ID helper (#23), and nothing else changes:
  the executor is the only piece that knows about privilege escalation.

The command itself is built so that only numbers and Base64 ever reach the
shell. The vendor and product identifiers are hex digits, the serial is a
decimal number, the path is derived from those, and the ladder travels as a
Base64 blob that `plutil -lint` checks before it is moved into place. There
is no interpolation of a display name, a serial string or any other text the
user could control.

The write is staged next to its destination and moved into place with
`mv -f`, so the file is never half-written, and an EXIT trap removes the
staged file if anything fails.

## Consequences

- The ladder generator, the path derivation and the idempotency check are
  tested without an administrator prompt and without a display.
- Swapping in the privileged helper is a change to one type, not to the
  feature.
- Until the helper exists, installing or removing a ladder asks for the
  administrator password. The UI says so, and only when a prompt is really
  coming: re-installing an identical ladder is a no-op and prompts for
  nothing.
- The feature is off by default. It is enabled per display, and the honest
  claim about it is "implemented, not yet verified on hardware".
