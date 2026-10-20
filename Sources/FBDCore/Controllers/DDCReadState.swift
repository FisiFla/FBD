import Foundation

/// A cached VCP read.
///
/// Reads are cached for a short while so that repeatedly asking a display for
/// the same feature does not keep its DDC controller busy: a monitor that
/// ignores part of its DDC traffic degrades the more it is asked, and a
/// degraded controller answers with garbage rather than with nothing.
///
/// The cache is dropped as soon as a write to the same feature lands, so the
/// next read asks the display rather than the cache.
public struct DDCReadCacheEntry: Equatable {
    public let currentValue: UInt16
    public let maxValue: UInt16
    public let timestamp: Date

    public init(currentValue: UInt16, maxValue: UInt16, timestamp: Date) {
        self.currentValue = currentValue
        self.maxValue = maxValue
        self.timestamp = timestamp
    }

    /// Whether the entry is too old to be trusted.
    public func isExpired(now: Date, ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(timestamp) > ttl
    }
}

/// Per-display read health: the consecutive-failure streak and the quarantine
/// window that follows it.
///
/// A display whose DDC controller stopped answering (a "deaf" channel) makes
/// every read cost the full I2C timeout. After a run of failures the display's
/// reads are quarantined for a while: they then fail fast instead of hanging,
/// and writes are untouched — a display that cannot be read can still be
/// driven.
///
/// One attempt that took longer than `deafAttempt` quarantines at once: such
/// an attempt is a channel that does not acknowledge at all rather than one
/// that answered with a garbled reply, and waiting for the full streak only
/// multiplies the wait for everyone.
///
/// The state machine is pure: it is driven by an injected clock, so it can be
/// tested without a display and without waiting.
public final class DDCReadHealth: @unchecked Sendable {
    /// Consecutive failures after which reads are quarantined.
    public static let defaultFailureThreshold = 6
    /// How long a quarantine lasts, seconds.
    public static let defaultQuarantineInterval: TimeInterval = 600
    /// An attempt at least this long counts as a deaf channel, seconds.
    public static let defaultDeafAttempt: TimeInterval = 3

    private var streaks: [String: Int] = [:]
    private var quarantineUntil: [String: Date] = [:]
    private let lock = NSLock()
    private let now: () -> Date

    public let failureThreshold: Int
    public let quarantineInterval: TimeInterval
    public let deafAttempt: TimeInterval

    public init(
        failureThreshold: Int = DDCReadHealth.defaultFailureThreshold,
        quarantineInterval: TimeInterval = DDCReadHealth.defaultQuarantineInterval,
        deafAttempt: TimeInterval = DDCReadHealth.defaultDeafAttempt,
        now: @escaping () -> Date = { Date() }
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.quarantineInterval = quarantineInterval
        self.deafAttempt = deafAttempt
        self.now = now
    }

    /// Whether reads for `key` are currently quarantined.
    ///
    /// An expired window clears the quarantine *and* the streak, so the next
    /// read is a fresh probe; if it fails, the display is quarantined again. A
    /// burst of failures therefore cannot cost reads for the rest of the
    /// session.
    public func isQuarantined(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = quarantineUntil[key] else { return false }
        guard now() < until else {
            quarantineUntil.removeValue(forKey: key)
            streaks[key] = 0
            return false
        }
        return true
    }

    /// Record a successful read: the failure streak is cleared.
    public func recordSuccess(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        streaks[key] = 0
    }

    /// Record a failed read attempt.
    ///
    /// - Returns: true when this failure quarantined the display.
    @discardableResult
    public func recordFailure(_ key: String, elapsed: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let until = quarantineUntil[key], now() >= until {
            quarantineUntil.removeValue(forKey: key)
            streaks[key] = 0
        }
        var streak = (streaks[key] ?? 0) + 1
        if elapsed >= deafAttempt {
            streak = max(streak, failureThreshold)
        }
        streaks[key] = streak
        guard streak >= failureThreshold else { return false }
        quarantineUntil[key] = now().addingTimeInterval(quarantineInterval)
        return true
    }

    /// The current failure streak for a display (0 when healthy).
    public func failureStreak(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return streaks[key] ?? 0
    }

    /// Forget everything about a display — a replug is the documented recovery
    /// for a wedged controller, and display identities change with it.
    public func reset(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        streaks.removeValue(forKey: key)
        quarantineUntil.removeValue(forKey: key)
    }
}
