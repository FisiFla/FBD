// UIDriver — CGEvent/Accessibility helper for the FBD UI smoke test.
//
// Subcommands:
//   click <x> <y>             Post a left mouse click at screen coordinates.
//   key <keycode>             Post a key down+up (e.g. 53 = Escape).
//   panel-state               Print "none" | "main" | "settings" for the
//                             FBD panel (main = 460x650, settings = 460x860).
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
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!
    down.post(tap: .cghidEventTap)
    usleep(80_000)
    up.post(tap: .cghidEventTap)
}

func postKey(_ keyCode: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)!
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

func panelState() -> String {
    let windows = fbdPanelWindows()
    guard !windows.isEmpty else { return "none" }
    // The settings page grows the panel to 860; the main page is 650.
    let bounds = windows.first?[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let height = bounds["Height"] as? Int ?? 0
    return height >= 800 ? "settings" : "main"
}

// MARK: - Accessibility

func fbdPid() -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == "dev.fisifla.fbd" }?
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
    print("usage: UIDriver <click|key|panel-state|ax-frame|ax-dump|status-frame|windows|status-sweep> ...")
    exit(2)
}

switch args[1] {
case "click":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { exit(2) }
    postClick(CGFloat(x), CGFloat(y))
    print("clicked \(args[2]),\(args[3])")

case "key":
    guard args.count >= 3, let code = UInt16(args[2]) else { exit(2) }
    postKey(CGKeyCode(code))
    print("key \(args[2])")

case "panel-state":
    print(panelState())

case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list {
        guard (window[kCGWindowOwnerName as String] as? String) == "FBD" else { continue }
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

case "status-sweep":
    let maxX = args.count >= 3 ? CGFloat(Double(args[2]) ?? 1710) : 1710
    let found = statusSweep(maxX: maxX)
    print(found)
    exit(found > 0 ? 0 : 1)

default:
    print("unknown subcommand \(args[1])")
    exit(2)
}
