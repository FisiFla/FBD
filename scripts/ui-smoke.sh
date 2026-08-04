#!/bin/bash
# FBD UI smoke test — drives the real panel via Accessibility + CGEvent.
#
# Verifies the core panel flow end-to-end:
#   1. status-item click opens the main page
#   2. the brightness slider click changes the display brightness
#   3. the gear opens Settings (panel grows to 860)
#   4. Back returns to the main page (panel shrinks to 650)
#   5. the close button hides the panel
#
# Requirements:
#   - Accessibility permission for the calling terminal/app
#   - FBD built (`make app`) — the test drives build/FBD.app
#   - the app binary must be signed or locally-built (ad-hoc is fine)
#
# Usage: bash scripts/ui-smoke.sh [--status-x <screen-x>]
# Exit 0 = all steps passed; 1 = any step failed (details printed).

set -u
cd "$(dirname "$0")/.."

STATUS_X_OVERRIDE=""
if [ "${1:-}" = "--status-x" ]; then
    STATUS_X_OVERRIDE="${2:-}"
fi

PASS=0
FAIL=0
step() { printf '  %-55s' "$1"; }
ok()   { echo "PASS"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL — $1"; FAIL=$((FAIL + 1)); }

DRIVER=build/UIDriver
mkdir -p build
if [ ! -x "$DRIVER" ] || [ "$DRIVER" -ot scripts/UIDriver.swift ]; then
    echo "[setup] compiling UIDriver"
    swiftc -O scripts/UIDriver.swift -o "$DRIVER" || { echo "UIDriver build failed"; exit 1; }
fi

# --- 0. App must be running -------------------------------------------------
if ! pgrep -f 'FBD.app/Contents/MacOS/FBD' >/dev/null; then
    echo "[setup] launching FBD"
    open build/FBD.app
    sleep 4
fi
if ! pgrep -f 'FBD.app/Contents/MacOS/FBD' >/dev/null; then
    echo "FATAL: FBD is not running"
    exit 1
fi

# --- 1. Open the panel via the status item ---------------------------------
step "status-item click opens the panel"
STATE=$($DRIVER panel-state)
if [ "$STATE" != "none" ]; then
    # Close whatever is open first for a clean start.
    $DRIVER key 53 >/dev/null 2>&1
    sleep 1
fi
if [ -n "$STATUS_X_OVERRIDE" ]; then
    FOUND_X=$STATUS_X_OVERRIDE
    $DRIVER click "$FOUND_X" 12 >/dev/null
    sleep 1.5
    STATE=$($DRIVER panel-state)
else
    FOUND_X=$($DRIVER status-sweep 2>/dev/null)
    STATE=$($DRIVER panel-state)
fi
# The panel remembers the last page (e.g. Settings from a previous session),
# so the status-item click can land on Settings — back out to main first.
if [ "$STATE" = "settings" ]; then
    FRAME=$($DRIVER ax-frame "Back to FBD" 2>/dev/null) || FRAME=""
    if [ -n "$FRAME" ]; then
        IFS=, read -r BX BY _ _ <<<"$FRAME"
        $DRIVER click "$((BX + 10))" "$((BY + 7))" >/dev/null
        sleep 1.5
        STATE=$($DRIVER panel-state)
    fi
fi

if [ "$STATE" = "main" ] && [ "$FOUND_X" != "0" ] && [ -n "$FOUND_X" ]; then
    ok
else
    bad "panel state '$STATE' after status-item click (found-x='$FOUND_X')"
fi

# --- 2. Brightness slider drives the display -------------------------------
step "brightness slider click changes brightness"
BEFORE=$(swift run --disable-sandbox fbdcli brightness 1 2>/dev/null | tail -1 | tr -dc '0-9.')
SLIDER=$($DRIVER ax-frame "Brightness for" 2>/dev/null) || SLIDER=""
if [ -z "$SLIDER" ]; then
    bad "brightness slider not found via AX"
else
    IFS=, read -r SX SY SW SH <<<"$SLIDER"
    # Click at 85% of the track, then 15% if that barely moved (the value
    # may have already been near 85%) — the check is "a click changes the
    # brightness", so pick the end that guarantees movement.
    DELTA=0
    for FRAC in 85 15; do
        X=$((SX + SW * FRAC / 100))
        $DRIVER click "$X" "$((SY + SH / 2))" >/dev/null
        sleep 2
        AFTER=$(swift run --disable-sandbox fbdcli brightness 1 2>/dev/null | tail -1 | tr -dc '0-9.')
        DELTA=$(awk -v a="$BEFORE" -v b="$AFTER" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')
        if awk -v d="$DELTA" 'BEGIN { exit !(d > 5) }'; then break; fi
    done
    if awk -v d="$DELTA" 'BEGIN { exit !(d > 5) }'; then
        ok
        # Restore the original brightness and let the app's debounced write
        # settle before the script exits (writes are debounced per display).
        swift run --disable-sandbox fbdcli brightness 1 "$BEFORE" >/dev/null 2>&1
        sleep 2
        CHECK=$(swift run --disable-sandbox fbdcli brightness 1 2>/dev/null | tail -1 | tr -dc '0-9.')
        RESTORE_DELTA=$(awk -v a="$BEFORE" -v b="$CHECK" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')
        if awk -v d="$RESTORE_DELTA" 'BEGIN { exit !(d > 5) }'; then
            echo "  [warn] brightness restore drifted ($BEFORE -> $CHECK)"
        fi
    else
        bad "brightness moved $DELTA% (before=$BEFORE after=$AFTER)"
    fi
fi

# --- 3. Gear opens Settings (panel grows) ----------------------------------
step "gear opens Settings (460x860)"
GEAR=$($DRIVER ax-frame "Settings" 2>/dev/null) || GEAR=""
if [ -z "$GEAR" ]; then
    bad "gear not found via AX"
else
    IFS=, read -r GX GY GW GH <<<"$GEAR"
    $DRIVER click "$((GX + GW / 2))" "$((GY + GH / 2))" >/dev/null
    sleep 2
    if [ "$($DRIVER panel-state)" = "settings" ]; then
        ok
    else
        bad "panel state is '$( $DRIVER panel-state)'"
    fi
fi

# --- 4. Back returns to main (panel shrinks) --------------------------------
step "Back returns to main page (460x650)"
BACK=$($DRIVER ax-frame "Back to FBD" 2>/dev/null) || BACK=""
if [ -z "$BACK" ]; then
    bad "back button not found via AX"
else
    IFS=, read -r BX BY BW BH <<<"$BACK"
    $DRIVER click "$((BX + BW / 2))" "$((BY + BH / 2))" >/dev/null
    sleep 2
    if [ "$($DRIVER panel-state)" = "main" ]; then
        ok
    else
        bad "panel state is '$( $DRIVER panel-state)'"
    fi
fi

# --- 5. Close button hides the panel ----------------------------------------
step "close button hides the panel"
CLOSE=$($DRIVER ax-frame "Close FBD panel" 2>/dev/null) || CLOSE=""
if [ -z "$CLOSE" ]; then
    bad "close button not found via AX"
else
    IFS=, read -r CX CY CW CH <<<"$CLOSE"
    $DRIVER click "$((CX + CW / 2))" "$((CY + CH / 2))" >/dev/null
    sleep 1.5
    if [ "$($DRIVER panel-state)" = "none" ]; then
        ok
    else
        bad "panel state is '$( $DRIVER panel-state)'"
    fi
fi

echo
echo "ui-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
