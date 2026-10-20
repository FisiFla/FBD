import Foundation

/// The DDC queues and the bus-traffic gate shared by the whole process.
///
/// Two jobs:
///
/// 1. **One serial queue per display.** A display that stops answering must
///    not stall the other displays, and the writes to one display have to stay
///    ordered.
/// 2. **A traffic gate for topology changes.** WindowServer's display enable
///    waits behind an in-flight I2C transaction and freezes the whole Mac
///    with it, so a topology change first pauses DDC traffic and waits for
///    what is already running to finish.
///
/// Traffic does not *wait* for the pause to end: a read or a write that
/// arrives during a topology change fails fast instead of blocking. Blocking
/// would be worse than failing — the main actor is usually the thread that
/// asked for the topology change, so a blocking DDC read there would
/// deadlock the change against itself.
///
/// The pool is process-wide on purpose: the gate has to cover every queue,
/// whoever created it.
public final class DDCQueuePool: @unchecked Sendable {
    /// The process-wide pool.
    public static let shared = DDCQueuePool()

    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]

    /// Guards the traffic state below.
    private let condition = NSCondition()
    /// Number of active holds; traffic is paused while it is not zero.
    private var holdCount = 0
    /// Transactions currently touching the bus.
    private var inFlight = 0

    public init() {}

    // MARK: - Queues

    /// The serial queue for a display.
    ///
    /// The queue is kept for the process lifetime: a display that is
    /// re-enumerated keeps its identity key, and a new queue would let a new
    /// operation overlap one still in flight.
    public func queue(for key: String) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[key] { return queue }
        let queue = DispatchQueue(label: "dev.fisifla.fbd.ddc.\(key)")
        queues[key] = queue
        return queue
    }

    // MARK: - Traffic gate

    /// Whether DDC traffic is currently paused.
    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holdCount > 0
    }

    /// Reserve the bus for one DDC transaction.
    ///
    /// - Returns: false when traffic is paused — the caller must not touch the
    ///   bus then. Never blocks, for the reason given in the type's comment.
    public func beginTransaction() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard holdCount == 0 else { return false }
        inFlight += 1
        return true
    }

    /// Release a reservation taken by `beginTransaction`.
    public func endTransaction() {
        condition.lock()
        defer { condition.unlock() }
        if inFlight > 0 { inFlight -= 1 }
        if inFlight == 0 { condition.broadcast() }
    }

    /// Pause DDC traffic until the returned hold is released.
    ///
    /// Waits for the transactions already in flight to finish — a read that
    /// takes six seconds to give up costs six seconds of waiting, while
    /// issuing the display change under it costs six seconds of a frozen Mac.
    /// The wait is bounded so a stuck transaction cannot wedge the change.
    public func hold(timeout: TimeInterval = 15) -> DDCQueuePool.Hold {
        condition.lock()
        holdCount += 1
        let deadline = Date().addingTimeInterval(timeout)
        while inFlight > 0 && condition.wait(until: deadline) {}
        condition.unlock()
        return Hold(pool: self)
    }

    /// Run `body` with DDC traffic paused.
    public func withTrafficPaused<T>(_ body: () throws -> T) rethrows -> T {
        let hold = hold()
        defer { hold.release() }
        return try body()
    }

    private func endHold() {
        condition.lock()
        defer { condition.unlock() }
        if holdCount > 0 { holdCount -= 1 }
        if holdCount == 0 { condition.broadcast() }
    }
}

extension DDCQueuePool {
    /// A paused-traffic token. Releasing it resumes DDC traffic.
    ///
    /// Releasing twice is harmless, and a hold that is never released is
    /// released when it goes out of scope — a leaked hold would otherwise
    /// silence DDC for the rest of the session.
    public final class Hold: @unchecked Sendable {
        private let pool: DDCQueuePool
        private var released = false
        private let lock = NSLock()

        init(pool: DDCQueuePool) {
            self.pool = pool
        }

        /// Resume DDC traffic.
        public func release() {
            lock.lock()
            let alreadyReleased = released
            released = true
            lock.unlock()
            guard !alreadyReleased else { return }
            pool.endHold()
        }

        deinit {
            release()
        }
    }
}
