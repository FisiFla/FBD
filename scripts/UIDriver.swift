// UIDriver — CGEvent/Accessibility helper for the FBD UI smoke test.
//
// Subcommands:
//   click <x> <y>             Post a left mouse click at screen coordinates.
//   key <keycode>             Post a key down+up (e.g. 53 = Escape).
//   panel-state               Print "none" | "open" for the FBD popover.
//   trusted                   Exit 0 if this process has Accessibility access.
//   ax-id <prefix>            Print "x,y,w,h" of the first FBD AX element whose
//                             identifier starts with <prefix>.
//   window-titled <title>     Exit 0 if FBD has a window titled <title>.
//   close-window <title>      Press the close button of that window.
//   ax-frame <desc>           Print "x,y,w,h" of the first FBD-process AX
//                             element whose accessibility description
//                             contains <desc> (screen coordinates).
//   status-sweep [maxX]       Sweep the menu bar right-to-left clicking
//                             candidate positions until the FBD panel opens;
//                             print the found x (0 = not found).
//
// Requires Accessibility permission for the calling process.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Events

func postClick(_ x: CGFloat, _ y: CGFloat) {
    let point = CGPoint(x: x, y: y)
    // Arrive first, as a pointer does: SwiftUI controls in the non-activating popover
    // track hover, and a click teleported onto one can be swallowed.
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!
        .post(tap: .cghidEventTap)
    usleep(150_000)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!
    down.post(tap: .cghidEventTap)
    usleep(80_000)
    up.post(tap: .cghidEventTap)
}

func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)!
    // Modifier flags must ride on the key events themselves: menu key
    // equivalents and SwiftUI .keyboardShortcut both read the event's flags.
    if !flags.isEmpty {
        down.flags = flags
        up.flags = flags
    }
    down.post(tap: .cghidEventTap)
    usleep(60_000)
    up.post(tap: .cghidEventTap)
}

// MARK: - Panel state

func fbdPanelWindows() -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { window in
        guard (window[kCGWindowOwnerName as String] as? String) == "FBD" else { return false }
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        let onscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
        return layer == 3 && onscreen
    }
}

/// The popover sizes itself to its page and Settings is a separate window, so the
/// panel's only states are shown or not.
func panelState() -> String {
    fbdPanelWindows().isEmpty ? "none" : "open"
}

// MARK: - Accessibility

/// Prefers this checkout's `build/FBD.app`: an installed copy shares the bundle id.
func fbdPid() -> pid_t? {
    let fbds = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "dev.fisifla.fbd" }
    return (fbds.first { $0.bundleURL?.path.hasSuffix("/build/FBD.app") == true } ?? fbds.first)?
        .processIdentifier
}

func axString(_ element: AXUIElement, _ attribute: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
    return value as? String ?? ""
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
    let pos = posRef as! AXValue
    let size = sizeRef as! AXValue
    var point = CGPoint.zero
    var rect = CGSize.zero
    AXValueGetValue(pos, .cgPoint, &point)
    AXValueGetValue(size, .cgSize, &rect)
    return CGRect(x: point.x, y: point.y, width: rect.width, height: rect.height)
}

/// Depth-first search for the first element whose description contains `needle`.
func findElement(_ element: AXUIElement, descriptionContains needle: String, depth: Int) -> AXUIElement? {
    if depth > 6 { return nil }
    let description = axString(element, kAXDescriptionAttribute as String)
    if description.localizedCaseInsensitiveContains(needle) {
        return element
    }
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else { return nil }
    for child in children {
        if let found = findElement(child, descriptionContains: needle, depth: depth + 1) {
            return found
        }
    }
    return nil
}

func findFrame(descriptionContains needle: String) -> CGRect? {
    guard let pid = fbdPid() else { return nil }
    let app = AXUIElementCreateApplication(pid)
    // The AX tree can lag briefly after a window appears; retry so the
    // smoke test does not flake on fresh panels.
    for _ in 0..<6 {
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                if let element = findElement(window, descriptionContains: needle, depth: 0),
                   let frame = axFrame(element) {
                    return frame
                }
            }
        }
        usleep(500_000)
    }
    return nil
}

/// Depth-first search for the first element whose identifier starts with `prefix`.
/// Deeper than the description search: page content sits inside a scroll view.
func findElement(_ element: AXUIElement, identifierPrefix prefix: String, depth: Int) -> AXUIElement? {
    if depth > 25 { return nil }
    if axString(element, kAXIdentifierAttribute as String).hasPrefix(prefix) { return element }
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else { return nil }
    for child in children {
        if let found = findElement(child, identifierPrefix: prefix, depth: depth + 1) { return found }
    }
    return nil
}

func fbdWindows() -> [AXUIElement] {
    guard let pid = fbdPid() else { return [] }
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windowsRef) == .success
    else { return [] }
    return windowsRef as? [AXUIElement] ?? []
}

func window(titled title: String) -> AXUIElement? {
    fbdWindows().first { axString($0, kAXTitleAttribute as String) == title }
}

// MARK: - Accessibility dump

/// The name a control carries when its label is drawn *beside* it — the AppKit
/// convention SwiftUI follows on macOS. Such a control exposes nothing through
/// `AXDescription`/`AXTitle` and points at the label element with
/// `AXTitleUIElement` instead, so reading only the former reports a perfectly
/// well-labelled checkbox as unlabelled.
func titleElementValue(of element: AXUIElement) -> String {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, "AXTitleUIElement" as CFString, &ref) == .success,
          let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return "" }
    return axString(unsafeBitCast(ref, to: AXUIElement.self), kAXValueAttribute as String)
}

/// Print one line per interactive accessibility element, so a control that
/// exposes no description — and therefore cannot be reached by assistive
/// technology — is visible rather than guessed at.
///
/// `includeStatic` adds `AXStaticText`, which is what a layout investigation
/// needs: the *positions* of captions and titles relative to their row are the
/// only way to tell a clipped row from an overlapping one.
func dumpElement(_ element: AXUIElement, depth: Int, includeStatic: Bool) {
    guard depth <= 8 else { return }
    let role = axString(element, kAXRoleAttribute as String)
    let description = axString(element, kAXDescriptionAttribute as String)
    let title = axString(element, kAXTitleAttribute as String)
    let identifier = axString(element, kAXIdentifierAttribute as String)
    let frame = axFrame(element)
    let indent = String(repeating: "  ", count: depth)
    // Static text would drown the list; these are the roles a user can act on.
    var interesting = [
        "AXButton", "AXSlider", "AXCheckBox", "AXPopUpButton", "AXRadioButton",
        "AXTextField", "AXMenuButton", "AXDisclosureTriangle", "AXTabGroup", "AXGroup",
    ]
    if includeStatic {
        interesting.append("AXStaticText")
    }
    if interesting.contains(role) {
        let place = frame.map { "@\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "@?"
        let viaTitleElement = titleElementValue(of: element)
        // Static text carries its string in AXValue, not in description/title —
        // without this the one case a layout investigation cares about reads blank.
        let staticValue = role == "AXStaticText" ? axString(element, kAXValueAttribute as String) : ""
        let label = !description.isEmpty
            ? description
            : (!title.isEmpty ? title : (!viaTitleElement.isEmpty ? viaTitleElement : staticValue))
        let marker = label.isEmpty ? "   <-- NO LABEL" : ""
        let source = viaTitleElement.isEmpty || !label.isEmpty && label != viaTitleElement
            ? ""
            : " (via AXTitleUIElement)"
        print("\(indent)\(role) id='\(identifier)' label='\(label)'\(source) \(place)\(marker)")
    }
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else { return }
    for child in children {
        dumpElement(child, depth: depth + 1, includeStatic: includeStatic)
    }
}

// MARK: - Status item sweep (superseded)

/// Superseded by `status-frame` and kept only as a fallback: it clicks the menu
/// bar every 8pt until a panel happens to open, which cannot tell a genuine hit
/// from a stale panel. `status-frame` reads the item's real frame from
/// `AXExtrasMenuBar` instead. Prefer that.
func statusSweep(maxX: CGFloat) -> Int {
    let y: CGFloat = 12
    var x = maxX
    while x >= 1300 {
        postClick(x, y)
        usleep(700_000)
        if panelState() != "none" { return Int(x) }
        x -= 8
    }
    return 0
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: UIDriver <click|key|panel-state|trusted|ax-frame|ax-id|ax-dump|status-frame|windows|window-titled|close-window|status-sweep> ...")
    exit(2)
}

switch args[1] {
case "click":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { exit(2) }
    postClick(CGFloat(x), CGFloat(y))
    print("clicked \(args[2]),\(args[3])")

case "key":
    guard args.count >= 3, let code = UInt16(args[2]) else { exit(2) }
    var flags: CGEventFlags = []
    if args.count >= 4 {
        for name in args[3].split(separator: ",") {
            switch name {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            default:
                FileHandle.standardError.write(Data("unknown modifier \(name)\n".utf8))
                exit(2)
            }
        }
    }
    postKey(CGKeyCode(code), flags: flags)
    print("key \(args[2])\(args.count >= 4 ? " [\(args[3])]" : "")")

case "panel-state":
    print(panelState())

case "trusted":
    // Accessibility is granted to the calling terminal; without it every AX lookup is empty.
    let trusted = AXIsProcessTrusted()
    print(trusted ? "trusted" : "not-trusted")
    exit(trusted ? 0 : 1)

case "windows":
    // Optional owner filter. The app owns FBD's panel, but its HUD, PiP and stream
    // windows belong to whichever process created them, so checking a second
    // process' windows has to say whose.
    let ownerFilter = args.count >= 3 ? args[2] : "FBD"
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list {
        guard (window[kCGWindowOwnerName as String] as? String) == ownerFilter else { continue }
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        let name = window[kCGWindowName as String] as? String ?? ""
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print("layer=\(layer) name='\(name)' \(bounds)")
    }

/// The status item's own frame, read from the accessibility tree rather than
/// guessed at.
///
/// An app's status items hang off its `AXExtrasMenuBar` attribute, and they are
/// **not** CGWindows — with the panel closed the process owns no windows at all,
/// which is exactly why the old code swept the menu bar clicking every 8pt until
/// something opened. That sweep could report a click that never touched the
/// status item, so the smoke test passed while testing nothing.
case "status-frame":
    guard let pid = fbdPid() else {
        print("not-found")
        exit(1)
    }
    let statusApp = AXUIElementCreateApplication(pid)
    var extrasRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(statusApp, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
          let extrasRef, CFGetTypeID(extrasRef) == AXUIElementGetTypeID() else {
        print("not-found")
        exit(1)
    }
    let extras = unsafeBitCast(extrasRef, to: AXUIElement.self)
    var itemsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString, &itemsRef) == .success,
          let items = itemsRef as? [AXUIElement],
          let item = items.first(where: { axFrame($0) != nil }),
          let frame = axFrame(item) else {
        print("not-found")
        exit(1)
    }
    print("\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")

case "ax-dump":
    guard let pid = fbdPid() else {
        print("FBD is not running")
        exit(1)
    }
    let app = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
       let windows = windowsRef as? [AXUIElement] {
        let includeStatic = args.contains("--all")
        for window in windows {
            dumpElement(window, depth: 0, includeStatic: includeStatic)
        }
    }

case "ax-frame":
    guard args.count >= 3 else { exit(2) }
    if let frame = findFrame(descriptionContains: args[2]) {
        print("\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
    } else {
        print("not-found")
        exit(1)
    }

case "ax-id":
    guard args.count >= 3 else { exit(2) }
    for _ in 0..<6 {
        for window in fbdWindows() {
            if let element = findElement(window, identifierPrefix: args[2], depth: 0), let frame = axFrame(element) {
                print("\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
                exit(0)
            }
        }
        usleep(500_000)
    }
    print("not-found")
    exit(1)

case "window-titled":
    guard args.count >= 3 else { exit(2) }
    exit(window(titled: args[2]) == nil ? 1 : 0)

case "close-window":
    guard args.count >= 3, let target = window(titled: args[2]) else { exit(1) }
    var buttonRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(target, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
          let buttonRef, CFGetTypeID(buttonRef) == AXUIElementGetTypeID() else { exit(1) }
    exit(AXUIElementPerformAction(unsafeBitCast(buttonRef, to: AXUIElement.self), kAXPressAction as CFString) == .success ? 0 : 1)

case "status-sweep":
    let maxX = args.count >= 3 ? CGFloat(Double(args[2]) ?? 1710) : 1710
    let found = statusSweep(maxX: maxX)
    print(found)
    exit(found > 0 ? 0 : 1)

default:
    print("unknown subcommand \(args[1])")
    exit(2)
}
