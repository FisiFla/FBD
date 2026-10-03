import CoreMedia
import Foundation

/// Per-stream capture rate (#14).
///
/// `SCStreamConfiguration.minimumFrameInterval` is the **maximum** interval
/// between frames, so a rate is its reciprocal. Pure, so the clamp and the
/// interval agree by construction and are testable without a live stream.
public enum StreamFrameRate {
    /// Used when a stream does not ask for a rate. Matches the value FBD used
    /// before the rate became configurable, so existing behaviour is unchanged.
    public static let `default` = 15

    /// Rates outside this range are **rejected by the parser**, not silently
    /// clamped: a typo should fail loudly rather than become a mystery rate.
    public static let range = 1...120

    /// The `minimumFrameInterval` for a rate.
    public static func interval(forFPS fps: Int) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(fps))
    }

    /// The rate a configuration should use, resolving "not specified" to the
    /// default and refusing nonsense rather than dividing by zero.
    public static func resolved(fps: Int?) -> Int {
        guard let fps, range.contains(fps) else { return `default` }
        return fps
    }

    /// A human-readable rate for the session listing.
    public static func label(fps: Int?) -> String {
        "\(resolved(fps: fps)) fps"
    }
}
