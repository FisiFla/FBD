#!/bin/bash
# FBD UI smoke test — drives the real popover via Accessibility + CGEvent.
#
# Verifies the core panel flow end-to-end:
#   1. status-item click opens the popover on the home page
#   2. the home page has a brightness slider (home.brightness.*), and clicking it
#      changes the display brightness
#   3. a display's chevron (home.display.*) opens its page (panel.back appears)
#   4. Back returns to the home page
#   5. Settings… (home.settings) opens the "FBD Settings" window
#   6. that window closes
#
# Requirements:
#   - Accessibility permission for the calling terminal/app
#   - FBD built (`make app`) — the test drives build/FBD.app from this checkout
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

if ! "$DRIVER" trusted >/dev/null; then
    echo "FATAL: this terminal lacks Accessibility permission (Privacy & Security → Accessibility)"
    exit 1
fi

# Only this checkout's build — an installed /Applications/FBD.app shares the bundle id.
APP_PATTERN="$(pwd)/build/FBD.app/Contents/MacOS/FBD"

# --- 0. App must be running -------------------------------------------------
if ! pgrep -f "$APP_PATTERN" >/dev/null; then
    echo "[setup] launching FBD"
    open build/FBD.app
    sleep 4
fi
if ! pgrep -f "$APP_PATTERN" >/dev/null; then
    echo "FATAL: build/FBD.app is not running"
    exit 1
fi

click_center() {
    IFS=, read -r X Y W H <<<"$1"
    "$DRIVER" click "$((X + W / 2))" "$((Y + H / 2))" >/dev/null
}

# Locate the status item from the accessibility tree, not by sweeping the menu bar.
if [ -n "$STATUS_X_OVERRIDE" ]; then
    STATUS_FRAME="$((STATUS_X_OVERRIDE - 1)),0,2,24"
else
    STATUS_FRAME=$("$DRIVER" status-frame 2>/dev/null) || STATUS_FRAME=""
fi

# Start from a verified closed popover: Escape closes it, the status item toggles it.
close_any_panel() {
    local tries=0
    while [ "$("$DRIVER" panel-state)" != "none" ] && [ "$tries" -lt 3 ]; do
        "$DRIVER" key 53 >/dev/null
        sleep 0.8
        if [ "$("$DRIVER" panel-state)" != "none" ] && [ -n "$STATUS_FRAME" ]; then
            click_center "$STATUS_FRAME"
            sleep 0.8
        fi
        tries=$((tries + 1))
    done
}

# --- 1. Open the popover via the status item ---------------------------------
step "status-item click opens the popover"
close_any_panel
if [ "$("$DRIVER" panel-state)" != "none" ]; then
    echo "FATAL: popover still open — refusing to test a stale panel"
    exit 1
fi
if [ -z "$STATUS_FRAME" ]; then
    bad "status item not found via AX"
else
    click_center "$STATUS_FRAME"
    sleep 1.5
    # The popover remembers its page; back out of a leftover detail page first.
    LEFTOVER=$("$DRIVER" ax-id panel.back 2>/dev/null) || LEFTOVER=""
    while [ -n "$LEFTOVER" ]; do
        click_center "$LEFTOVER"
        sleep 1
        LEFTOVER=$("$DRIVER" ax-id panel.back 2>/dev/null) || LEFTOVER=""
    done
    STATE=$("$DRIVER" panel-state)
    if [ "$STATE" = "open" ]; then ok; else bad "panel state '$STATE' after status-item click"; fi
fi

# --- 2. Brightness slider exists and drives the display -----------------------
step "home brightness slider changes brightness"
SLIDER=$("$DRIVER" ax-id home.brightness. 2>/dev/null) || SLIDER=""
if [ -z "$SLIDER" ]; then
    bad "home.brightness.* not found via AX"
else
    BEFORE=$(swift run --disable-sandbox fbdcli brightness 1 2>/dev/null | tail -1 | tr -dc '0-9.')
    IFS=, read -r SX SY SW SH <<<"$SLIDER"
    # Click at 85% of the track, then 15% if that barely moved — the check is
    # "a click changes the brightness", so pick the end that guarantees movement.
    DELTA=0
    AFTER=$BEFORE
    for FRAC in 85 15; do
        "$DRIVER" click "$((SX + SW * FRAC / 100))" "$((SY + SH / 2))" >/dev/null
        sleep 2
        AFTER=$(swift run --disable-sandbox fbdcli brightness 1 2>/dev/null | tail -1 | tr -dc '0-9.')
        DELTA=$(awk -v a="$BEFORE" -v b="$AFTER" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')
        if awk -v d="$DELTA" 'BEGIN { exit !(d > 5) }'; then break; fi
    done
    if awk -v d="$DELTA" 'BEGIN { exit !(d > 5) }'; then
        ok
        # Restore the original brightness and let the debounced write settle.
        swift run --disable-sandbox fbdcli brightness 1 "$BEFORE" >/dev/null 2>&1
        sleep 2
    else
        bad "brightness moved $DELTA% (before=$BEFORE after=$AFTER)"
    fi
fi

# --- 3. Display chevron opens the display page --------------------------------
step "display chevron opens the display page"
CHEVRON=$("$DRIVER" ax-id home.display. 2>/dev/null) || CHEVRON=""
if [ -z "$CHEVRON" ]; then
    bad "home.display.* not found via AX"
else
    click_center "$CHEVRON"
    sleep 1.5
    if "$DRIVER" ax-id panel.back >/dev/null 2>&1; then ok; else bad "panel.back not found on the display page"; fi
fi

# --- 4. Back returns to the home page -----------------------------------------
step "Back returns to the home page"
BACK=$("$DRIVER" ax-id panel.back 2>/dev/null) || BACK=""
if [ -z "$BACK" ]; then
    bad "panel.back not found via AX"
else
    click_center "$BACK"
    sleep 1.5
    if "$DRIVER" ax-id home.settings >/dev/null 2>&1; then ok; else bad "home page not shown after Back"; fi
fi

# --- 5. Settings… opens the Settings window -----------------------------------
step "Settings… opens the FBD Settings window"
SETTINGS=$("$DRIVER" ax-id home.settings 2>/dev/null) || SETTINGS=""
if [ -z "$SETTINGS" ]; then
    bad "home.settings not found via AX"
else
    click_center "$SETTINGS"
    sleep 2
    if "$DRIVER" window-titled "FBD Settings"; then ok; else bad "no window titled 'FBD Settings'"; fi
fi

# --- 6. The Settings window closes ---------------------------------------------
step "Settings window closes"
"$DRIVER" close-window "FBD Settings" >/dev/null 2>&1
sleep 1
if "$DRIVER" window-titled "FBD Settings"; then bad "window still open"; else ok; fi

close_any_panel

echo
echo "ui-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
