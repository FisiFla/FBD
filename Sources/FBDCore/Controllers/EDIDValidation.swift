import Foundation

/// Structural EDID validation shared by the CLI, the controller and the
/// persistence layer (defense in depth: only structurally sound EDIDs reach
/// the display registry or UserDefaults).
///
/// An EDID is: a 128-byte base block (header `00 FF FF FF FF FF FF 00`, last
/// byte = checksum making the block sum ≡ 0 mod 256) plus 0..3 optional
/// 128-byte extension blocks (total ≤ 512 bytes, extensions count in byte
/// 126).
public enum EDIDValidation {
    /// nil when `data` is a structurally valid EDID, otherwise a
    /// human-readable reason for the rejection.
    public static func validate(_ data: Data) -> String? {
        guard data.count >= 128 else {
            return "must be at least 128 bytes (got \(data.count))"
        }
        guard data.count <= 512 else {
            return "must be at most 512 bytes (got \(data.count))"
        }
        guard data.count % 128 == 0 else {
            return "must be a multiple of 128 bytes (got \(data.count))"
        }
        let header = [UInt8](data.prefix(8))
        let expected: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard header == expected else {
            return "missing the EDID header (00 FF FF FF FF FF FF 00)"
        }
        // Base-block checksum: all 128 bytes sum to 0 (mod 256).
        let sum = data.prefix(128).reduce(0) { ($0 + Int($1)) & 0xFF }
        guard sum == 0 else {
            return "base block checksum mismatch"
        }
        return nil
    }

    /// Convenience: true when `data` passes `validate`.
    public static func isValid(_ data: Data) -> Bool {
        validate(data) == nil
    }
}
