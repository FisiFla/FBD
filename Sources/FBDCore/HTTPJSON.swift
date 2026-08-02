import CoreGraphics
import Foundation

/// JSON helpers shared by the app's HTTP API handler and the pure
/// `HTTPRouter` (FBDCore so both are unit-testable).
public enum HTTPJSON {
    /// Compact JSON string for an HTTP response.
    public static func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"error":"encoding failed"}"#
        }
        return String(data: data, encoding: .utf8) ?? #"{"error":"encoding failed"}"#
    }

    public static func error(_ message: String) -> String {
        encode(["error": message])
    }

    public static func parse(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Parse a display id: plain decimal, or 0x-prefixed hex.
    public static func parseDisplayID(_ string: String) -> CGDirectDisplayID? {
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            return CGDirectDisplayID(string.dropFirst(2), radix: 16)
        }
        return CGDirectDisplayID(string)
    }

    /// JSON object for one display (list + info endpoints).
    public static func display(_ display: Display) -> [String: Any] {
        var info: [String: Any] = [
            "id": display.id,
            "name": display.name,
            "builtin": display.isBuiltin,
            "virtual": display.isVirtual,
            "online": display.isOnline,
            "active": display.isActive,
            "ddc": display.ddcAvailable,
            "appleBrightness": display.appleBrightnessAvailable,
            "bounds": [
                "x": display.bounds.origin.x,
                "y": display.bounds.origin.y,
                "width": display.bounds.width,
                "height": display.bounds.height,
            ],
        ]
        if let brightness = display.brightness {
            info["brightness"] = brightness
        }
        if let mode = display.currentMode {
            info["currentMode"] = mode.key
        }
        info["xdrCapable"] = display.isXDRCapable
        info["xdrUpscaled"] = display.isXDRUpscaled
        if let target = display.xdrUpscaleTargetNits {
            info["xdrTargetNits"] = target
        }
        return info
    }

    public static func mode(_ mode: DisplayMode) -> [String: Any] {
        [
            "key": mode.key,
            "width": mode.pixelsWide,
            "height": mode.pixelsHigh,
            "hz": mode.refreshRate,
            "hidpi": mode.isHiDPI,
            "safe": mode.isSafe,
        ]
    }

    /// Best matching mode for (width, height, hz): same physical pixels,
    /// nearest refresh rate, HiDPI preferred, then safe. `hz` nil keeps the
    /// display's current refresh rate when possible.
    public static func bestMode(matchingWidth width: Int32, height: Int32, hz: Double?, in display: Display) -> DisplayMode? {
        let candidates = display.modes.filter { $0.pixelsWide == width && $0.pixelsHigh == height }
        guard !candidates.isEmpty else { return nil }
        if let hz {
            return candidates.sorted { a, b in
                let distanceA = abs(a.refreshRate - hz)
                let distanceB = abs(b.refreshRate - hz)
                if distanceA != distanceB { return distanceA < distanceB }
                if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
                if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
                return a.isSafe && !b.isSafe
            }.first
        }
        if let current = display.currentMode,
           let sameRate = candidates.first(where: { $0.refreshRate == current.refreshRate }) {
            return sameRate
        }
        return candidates.sorted { a, b in
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.isSafe && !b.isSafe
        }.first
    }
}
