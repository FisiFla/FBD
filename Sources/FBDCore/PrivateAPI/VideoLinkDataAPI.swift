import CPrivateAPI
import Foundation
import os

/// The DisplayPort link-data read path: the pair of IOKit entry points BetterDisplay 5 uses
/// for the DPCD / DSC / link-bandwidth / tiling facts of a display.
///
/// **Probe only — nothing here reads link data.** Two reasons, both measured:
///
/// - `IOAVVideoInterfaceGetLinkData` returns a structure that no public header describes, so
///   its fields cannot be decoded safely. A wrong guess would put invented numbers into a
///   bug report, which is worse than no numbers at all.
/// - `IOAVVideoInterfaceCreateWithService` was measured raising a kernel trap (SIGTRAP)
///   when handed the only display this repository's machine has, so calling it is not free
///   either.
///
/// What FBD asks instead is the one question that *can* be answered safely: is the entry
/// point present on this macOS? That is the difference between "this Mac cannot report
/// link data" and "no Mac can", and a bug report needs to be able to say which.
public enum VideoLinkDataAPI {
    private static let log = Logger(subsystem: "dev.fisifla.fbd", category: "VideoLinkDataAPI")

    /// True when both entry points resolve on this macOS.
    ///
    /// This is **symbol resolution, not a call**: no link data is read, ever.
    public static var isAvailable: Bool { FBDVideoLinkDataAvailable() }

    /// Resolve the entry points and log when they are missing.
    ///
    /// The call site is a report or a diagnostic, so the miss is worth a log line; the
    /// missing capability is not an error, only a fact.
    @discardableResult
    public static func probe() -> Bool {
        let available = isAvailable
        if !available {
            log.debug("the DisplayPort link-data entry points do not resolve on this macOS")
        }
        return available
    }

    /// Why the link facts cannot be reported, in one sentence.
    ///
    /// Kept here rather than in the report code so that the wording lives next to the
    /// decision not to call the entry points.
    public static var unavailableReason: String {
        if isAvailable {
            return "IOAVVideoInterfaceGetLinkData resolves here but returns a structure "
                + "that no public header describes, so its fields cannot be read safely"
        }
        return "this macOS has no IOAVVideoInterfaceGetLinkData entry point"
    }
}
