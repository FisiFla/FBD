import Foundation

/// Errors surfaced by the private-API layer. Callers degrade gracefully.
public enum PrivateAPIError: Error, LocalizedError, Equatable {
    /// A C API returned a non-zero status.
    case status(String, Int32)
    /// A symbol/framework is missing on this OS version (degradation path).
    case unavailable(String)
    /// I2C/DDC transaction failed.
    case i2c(String)
    /// No matching service found in the IORegistry.
    case serviceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .status(let api, let code):
            return "\(api) failed with status \(code)"
        case .unavailable(let what):
            return "\(what) is not available on this system"
        case .i2c(let what):
            return "I2C transaction failed: \(what)"
        case .serviceNotFound(let what):
            return "No matching I/O service: \(what)"
        }
    }
}
