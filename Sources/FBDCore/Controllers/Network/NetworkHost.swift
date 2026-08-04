import Foundation

/// Shared networking helpers for the display-network controllers
/// (LG/Tizen/Philips/Yamaha).
enum NetworkHost {
    /// Brackets IPv6 literals so `URL(string:)` accepts them (RFC 3986).
    /// IPv4 hosts and already-bracketed literals pass through unchanged.
    static func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}
