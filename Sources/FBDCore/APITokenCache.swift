import Foundation

/// The HTTP API token, resolved off the main actor and served from memory.
///
/// `Settings.httpAPIToken` reads the login Keychain, and `SecItemCopyMatching`
/// blocks on a modal "allow access?" prompt when the calling binary is not in
/// the item's access control list. On the main actor that prompt freezes the
/// whole app — the menu bar, the settings window, and the HTTP API, because
/// every request waits for the main actor to answer it.
///
/// So the token is read once, off the main actor, and cached; afterwards the
/// Keychain is not touched at all.
///
/// `resolve()` may block on that prompt. **Never call it from the main
/// actor** — call `peek()` there instead, which fails closed when the token
/// has not been resolved yet.
public final class APITokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: String?
    private let read: () -> String

    /// - Parameter read: how the token is fetched. The default reads the
    ///   Keychain; tests inject a closure.
    public init(read: @escaping () -> String = { Settings.httpAPIToken }) {
        self.read = read
    }

    /// The token if it has already been resolved — never touches the Keychain,
    /// so it is safe to call from the main actor. `nil` means "not resolved
    /// yet": a caller that cannot wait must fail closed.
    public func peek() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// The token, resolving it on a miss.
    ///
    /// May block on a Keychain access prompt, so it must not run on the main
    /// actor. The read happens under the lock, so at most one prompt is ever
    /// outstanding: a second caller waits for the first instead of raising a
    /// second dialog.
    public func resolve() -> String {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        // Deliberately under the lock — one prompt at a time.
        let token = read()
        cached = token
        lock.unlock()
        return token
    }

    /// Drop the cached token — the item was deleted or rotated.
    public func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}
