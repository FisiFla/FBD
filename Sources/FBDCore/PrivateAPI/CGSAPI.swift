import CoreGraphics
import CPrivateAPI
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "CGSAPI")

/// Typed wrappers over the private CoreGraphicsServices (CGS) display APIs.
/// Same API family used by displayplacer.
public enum CGSAPI {
    /// Active (online) display IDs. CGSGetDisplayList also reports offline-but-present
    /// displays; callers wanting only active displays should prefer CGGetActiveDisplayList.
    public static func displayList() throws -> [CGDirectDisplayID] {
        var count: Int32 = 0
        var status = CGSGetDisplayList(16, nil, &count)
        guard status == .success, count > 0 else {
            throw PrivateAPIError.status("CGSGetDisplayList", status.rawValue)
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        status = displays.withUnsafeMutableBufferPointer { buffer in
            CGSGetDisplayList(Int32(buffer.count), buffer.baseAddress, &count)
        }
        guard status == .success else { throw PrivateAPIError.status("CGSGetDisplayList", status.rawValue) }
        return Array(displays.prefix(Int(count)))
    }

    public static func currentModeNumber(for displayID: CGDirectDisplayID) throws -> Int32 {
        var mode: Int32 = 0
        let status = CGSGetCurrentDisplayMode(displayID, &mode)
        guard status == .success else { throw PrivateAPIError.status("CGSGetCurrentDisplayMode", status.rawValue) }
        return mode
    }

    public static func numberOfModes(for displayID: CGDirectDisplayID) throws -> Int32 {
        var count: Int32 = 0
        let status = CGSGetNumberOfDisplayModes(displayID, &count)
        guard status == .success else { throw PrivateAPIError.status("CGSGetNumberOfDisplayModes", status.rawValue) }
        return count
    }

    /// Fetch all display modes for a display, as CGSDisplayModeDescription structs.
    public static func modeDescriptions(for displayID: CGDirectDisplayID) throws -> [CGSDisplayModeDescription] {
        let count = try numberOfModes(for: displayID)
        guard count > 0 else { return [] }
        var descriptions: [CGSDisplayModeDescription] = []
        descriptions.reserveCapacity(Int(count))
        for index in 0..<count {
            var desc = CGSDisplayModeDescription()
            let status = CGSGetDisplayModeDescriptionOfLength(displayID, index, &desc, Int32(MemoryLayout<CGSDisplayModeDescription>.size))
            guard status == .success else {
                log.warning("CGSGetDisplayModeDescriptionOfLength failed for mode \(index) on \(displayID): \(status.rawValue)")
                continue
            }
            descriptions.append(desc)
        }
        return descriptions
    }

    /// Apply a mode via a display configuration transaction (permanent).
    public static func configureMode(_ modeNumber: Int32, on displayID: CGDirectDisplayID) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            throw PrivateAPIError.status("CGBeginDisplayConfiguration", begin.rawValue)
        }
        let status = CGSConfigureDisplayMode(config, displayID, modeNumber)
        guard status == .success else {
            CGCancelDisplayConfiguration(config)
            throw PrivateAPIError.status("CGSConfigureDisplayMode", status.rawValue)
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            throw PrivateAPIError.status("CGCompleteDisplayConfiguration", complete.rawValue)
        }
    }
}
