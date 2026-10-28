import Foundation
import os

/// DDC/CI controller: VCP reads/writes and capabilities over the Apple Silicon
/// IOAVService I2C transport.
///
/// Concurrency model:
/// - All I2C traffic for a display is serialized on a per-display queue
///   (see `DDCQueuePool`).
/// - **Set-VCP writes are enqueued asynchronously**, coalesced latest-wins per
///   (display, VCP code), and spaced by
///   `Settings.ddcCooldownMilliseconds` (some displays glitch when the DDC bus
///   is hammered — OSD flicker, dropped replies). `writeVCP` returns
///   immediately; it only reports whether the request was accepted for delivery.
/// - **Reads are synchronous** (request write + settle + reply read), paced by
///   `Settings.ddcReadCooldownMilliseconds` and served from a short-lived
///   cache (`Settings.ddcReadCacheSeconds`). They may block the calling
///   thread briefly; never call them from a hot path.
///
/// The hardening contract (validated replies, TTL cache, quarantine, topology
/// hold) is documented in `docs/ddc-equivalence.md`, the code-level audit
/// against didriksg/Crisp v1.7.1.
///
/// Never throws: failures degrade to nil/false with a logged warning.
///
/// Wire framing follows m1ddc (see `DDC`). It has been exercised against one external
/// monitor (2026-10-28); a second display is still untested.
public final class DDCController {
    private let external: ExternalControlling
    /// Whether the DDC transport is supported on this host (Apple Silicon).
    /// Injectable so mock-based tests can run on any architecture.
    private let isPlatformSupported: () -> Bool
    /// The shared per-display queues and the traffic gate.
    private let queuePool: DDCQueuePool
    /// Per-display read health: failure streaks and quarantine windows.
    private let readHealth: DDCReadHealth
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DDCController")

    /// Next allowed set-write deadline per display (cooldown bookkeeping).
    private var nextWriteAt: [String: DispatchTime] = [:]
    /// Latest value awaiting delivery per display → VCP code. A newer write for the same code
    /// replaces the value of the already-scheduled slot instead of queuing another.
    private var pendingWrites: [String: [UInt8: UInt16]] = [:]
    /// Cached maximum values from the last successful VCP read, keyed by display → code.
    private var lastMaxValue: [String: [UInt8: UInt16]] = [:]
    /// Recently read VCP values per display → code, with the time they were read.
    private var readCache: [String: [UInt8: DDCReadCacheEntry]] = [:]
    /// Next allowed read deadline per display (read pacing bookkeeping).
    private var nextReadAt: [String: DispatchTime] = [:]
    /// Displays we already attempted a live capabilities read for (fallback path).
    private var liveCapabilitiesChecked: Set<String> = []
    private let lock = NSLock()

    public init(
        external: ExternalControlling,
        isPlatformSupported: @escaping () -> Bool = { IOAVServiceAPI.isAppleSilicon },
        queuePool: DDCQueuePool = .shared,
        readHealth: DDCReadHealth = DDCReadHealth()
    ) {
        self.external = external
        self.isPlatformSupported = isPlatformSupported
        self.queuePool = queuePool
        self.readHealth = readHealth
    }

    // MARK: - Availability

    /// DDC is usable when running natively on Apple Silicon and an AVService
    /// exists for the display.
    public func isAvailable(for display: Display) -> Bool {
        guard isPlatformSupported() else { return false }
        return external.avService(for: display) != nil
    }

    /// Whether DDC traffic is currently paused for a display topology change.
    ///
    /// A read that arrives during such a change fails fast instead of
    /// blocking, so a caller that was refused for that reason can try again
    /// later rather than having to guess.
    public var isTrafficPaused: Bool { queuePool.isPaused }

    // MARK: - Queue + write scheduling

    private func queue(for display: Display) -> DispatchQueue {
        queuePool.queue(for: display.identityKey)
    }

    /// Reserve the next allowed set-write slot for a display and return its
    /// deadline. Consecutive calls are spaced by the cooldown.
    private func nextWriteSlot(for key: String) -> DispatchTime {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now()
        let slot = max(nextWriteAt[key] ?? now, now)
        nextWriteAt[key] = slot + .milliseconds(Settings.ddcCooldownMilliseconds)
        return slot
    }

    /// Reserve the next allowed read slot for a display and wait for it.
    ///
    /// Reads are paced with the same discipline as writes: a display's DDC
    /// controller answers less often the more it is asked, and the cost of a
    /// controller that answers rarely is a display whose brightness slider
    /// does nothing.
    private func waitForReadSlot(for key: String) {
        let slot = nextReadSlot(for: key)
        let now = DispatchTime.now()
        guard slot > now else { return }
        let delay = Double(slot.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
        Thread.sleep(forTimeInterval: delay)
    }

    private func nextReadSlot(for key: String) -> DispatchTime {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now()
        let slot = max(nextReadAt[key] ?? now, now)
        nextReadAt[key] = slot + .milliseconds(Settings.ddcReadCooldownMilliseconds)
        return slot
    }

    // MARK: - Read cache

    /// The cached value for a feature, when it is still fresh.
    private func cachedRead(_ code: UInt8, for key: String) -> DDC.DDCValue? {
        let ttl = TimeInterval(Settings.ddcReadCacheSeconds)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = readCache[key]?[code] else { return nil }
        guard !entry.isExpired(now: Date(), ttl: ttl) else {
            readCache[key]?.removeValue(forKey: code)
            return nil
        }
        return DDC.DDCValue(maxValue: entry.maxValue, currentValue: entry.currentValue)
    }

    private func cacheRead(_ code: UInt8, value: DDC.DDCValue, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        readCache[key, default: [:]][code] = DDCReadCacheEntry(
            currentValue: value.currentValue,
            maxValue: value.maxValue,
            timestamp: Date()
        )
    }

    /// Drop the cached value of a feature — the display now holds a value we
    /// have not read back, so the next read has to ask the display.
    private func invalidateCachedRead(_ code: UInt8, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        readCache[key]?.removeValue(forKey: code)
    }

    // MARK: - VCP

    /// Read a VCP feature. Synchronous: write request → settle → read 12-byte
    /// reply → validate → parse. Retries up to `Settings.ddcReadRetries` extra
    /// attempts (some monitors only answer on the 2nd–3rd try). Returns nil on
    /// failure.
    public func readVCP(_ code: UInt8, for display: Display) -> DDC.DDCValue? {
        guard isAvailable(for: display) else { return nil }
        return queue(for: display).sync { self.vcpValueOnQueue(code, for: display) }
    }

    /// The retry loop, for callers already running on the display's queue.
    ///
    /// `readVCP` wraps this in `queue.sync`. A caller that is *already* on that
    /// queue must call this directly, because `queue.sync` from inside it is a
    /// deadlock rather than a nested call.
    ///
    /// `paced` is false for the follow-up reads of one operation: the panel
    /// reads four features in one pass, and giving each of them its own
    /// pacing slot would quadruple the wait for no benefit.
    private func vcpValueOnQueue(
        _ code: UInt8,
        for display: Display,
        paced: Bool = true
    ) -> DDC.DDCValue? {
        let key = display.identityKey
        if let cached = cachedRead(code, for: key) { return cached }
        guard !readHealth.isQuarantined(key) else {
            log.notice("readVCP: reads are quarantined for \(display.id) — not touching the bus")
            return nil
        }
        if paced { waitForReadSlot(for: key) }
        let attempts = max(1, Settings.ddcReadRetries + 1)
        for attempt in 1...attempts {
            if let value = attemptVCPRead(code, for: display) {
                cacheRead(code, value: value, for: key)
                return value
            }
            if attempt < attempts {
                log.debug("readVCP: attempt \(attempt)/\(attempts) failed for \(display.id) (code \(String(format: "0x%02X", code))) — retrying")
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        log.warning("readVCP: all \(attempts) attempts failed for \(display.id) (code \(String(format: "0x%02X", code)))")
        return nil
    }

    /// One request → settle → reply → validate → parse cycle (see `readVCP`
    /// for retries).
    private func attemptVCPRead(_ code: UInt8, for display: Display) -> DDC.DDCValue? {
        let key = display.identityKey
        // The gate refuses the transaction outright while a display topology
        // change is in progress: blocking here would stall the very change
        // that asked for the read.
        guard queuePool.beginTransaction() else {
            log.notice("readVCP: DDC traffic is paused (display topology change) — skipping \(display.id)")
            return nil
        }
        defer { queuePool.endTransaction() }

        let started = DispatchTime.now()
        guard external.writeI2C(DDC.i2cAddress, data: Data(DDC.readVCPRequest(code: code)), for: display) else {
            recordReadFailure(key, display: display, started: started, code: code)
            log.warning("readVCP: request write failed for \(display.id) (code \(String(format: "0x%02X", code)))")
            return nil
        }
        // Give the display a moment to prepare its reply.
        Thread.sleep(forTimeInterval: Double(Settings.ddcSettleMilliseconds) / 1000)
        guard let reply = external.readI2C(DDC.i2cAddress, length: DDC.vcpReplyLength, for: display) else {
            recordReadFailure(key, display: display, started: started, code: code)
            log.warning("readVCP: no reply for \(display.id) (code \(String(format: "0x%02X", code)))")
            return nil
        }
        guard let parsed = DDC.parseVCPReply(reply, expecting: code) else {
            recordReadFailure(key, display: display, started: started, code: code)
            log.warning("readVCP: malformed reply for \(display.id) (code \(String(format: "0x%02X", code)))")
            return nil
        }
        readHealth.recordSuccess(key)
        rememberMax(parsed.value.maxValue, code: code, for: display)
        return parsed.value
    }

    /// Record a failed read attempt and log when it quarantined the display.
    private func recordReadFailure(
        _ key: String,
        display: Display,
        started: DispatchTime,
        code: UInt8
    ) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        guard readHealth.recordFailure(key, elapsed: elapsed) else { return }
        let threshold = readHealth.failureThreshold
        let interval = Int(readHealth.quarantineInterval)
        log.notice(
            "readVCP: \(display.id) failed \(threshold) times in a row (code \(String(format: "0x%02X", code))) — quarantining its reads for \(interval) s"
        )
    }

    /// Write a VCP feature. Returns true when the write was accepted for
    /// delivery (display has an AVService and the op is queued); delivery is
    /// asynchronous and spaced by the per-display cooldown.
    @discardableResult
    public func writeVCP(_ code: UInt8, value: UInt16, for display: Display) -> Bool {
        guard isAvailable(for: display) else { return false }
        let key = display.identityKey
        let q = queue(for: display)
        lock.lock()
        let alreadyPending = pendingWrites[key]?[code] != nil
        pendingWrites[key, default: [:]][code] = value
        lock.unlock()
        // The display is about to hold a value we have not read back: drop the
        // cached read now, so the next read asks the display rather than the
        // cache.
        invalidateCachedRead(code, for: key)
        // A slot is already scheduled for this code: it will pick up the newer value.
        if alreadyPending { return true }
        let slot = nextWriteSlot(for: key)
        q.asyncAfter(deadline: slot) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let latest = self.pendingWrites[key]?.removeValue(forKey: code)
            self.lock.unlock()
            guard let latest else { return }
            guard self.queuePool.beginTransaction() else {
                self.log.notice("writeVCP: DDC traffic is paused (display topology change) — dropping the write for \(display.id)")
                return
            }
            defer { self.queuePool.endTransaction() }
            let data = Data(DDC.writeVCPPacket(code: code, value: latest))
            guard self.external.writeI2C(DDC.i2cAddress, data: data, for: display) else {
                self.log.warning("writeVCP failed for \(display.id) (code \(String(format: "0x%02X", code)))")
                return
            }
        }
        return true
    }

    /// High-level feature read: continuous features return a normalized 0…1
    /// value, discrete features (mute, input source) return the raw current value.
    public func getFeature(_ feature: DDCFeature, for display: Display) -> Double? {
        guard let value = readVCP(feature.vcpCode, for: display) else { return nil }
        if feature.isContinuous {
            return value.normalized
        }
        return Double(value.currentValue)
    }

    /// `getFeature`'s body, for a caller already on the display's queue.
    private func featureValueOnQueue(
        _ feature: DDCFeature,
        for display: Display,
        paced: Bool = true
    ) -> Double? {
        guard let value = vcpValueOnQueue(feature.vcpCode, for: display, paced: paced) else { return nil }
        return feature.isContinuous ? value.normalized : Double(value.currentValue)
    }

    /// Read the DDC panel's three read-back values in **one** pass on the
    /// display's queue, returning on the main actor.
    ///
    /// The synchronous accessors each do their own `queue.sync`, so refreshing the
    /// panel blocked the main actor three times over — the same problem the
    /// capabilities probe had. This reads all three while already on the queue,
    /// which is also why it calls `featureValueOnQueue` rather than `getFeature`.
    public func readState(
        for display: Display,
        completion: @escaping @MainActor (DDC.DDCState) -> Void
    ) {
        guard isAvailable(for: display) else {
            Task { @MainActor in completion(DDC.DDCState()) }
            return
        }
        queue(for: display).async { [weak self] in
            guard let self else { return }
            // Only the first read of the pass takes a pacing slot: the four
            // features belong to one operation.
            let state = DDC.DDCState(
                contrast: self.featureValueOnQueue(.contrast, for: display, paced: true),
                volume: self.featureValueOnQueue(.volume, for: display, paced: false),
                muted: self.featureValueOnQueue(.mute, for: display, paced: false).map(DDC.isMuted),
                inputSource: self.featureValueOnQueue(.inputSource, for: display, paced: false)
            )
            Task { @MainActor in completion(state) }
        }
    }

    /// High-level feature write: continuous features scale `value` (0…1)
    /// against the feature's maximum; discrete features take the raw value.
    /// Asynchronous — returns whether the write was accepted for delivery.
    @discardableResult
    public func setFeature(_ feature: DDCFeature, value: Double, for display: Display) -> Bool {
        let raw: UInt16
        if feature.isContinuous {
            let clamped = min(max(value, 0), 1)
            let maxValue = maxValue(for: feature.vcpCode, display: display)
            raw = UInt16((clamped * Double(maxValue)).rounded())
        } else {
            raw = UInt16(min(max(value, 0), 65535))
        }
        guard writeVCP(feature.vcpCode, value: raw, for: display) else {
            log.warning("setFeature \(feature.settingsKey) failed for \(display.id)")
            return false
        }
        return true
    }

    // MARK: - Capabilities

    /// Read and parse the display's capabilities reply (VCP 0xF3).
    /// The reply is fetched fragment by fragment (32 bytes per request) and
    /// concatenated.
    public func readCapabilities(for display: Display) -> DDC.DDCCapabilities? {
        guard isAvailable(for: display) else { return nil }
        return queue(for: display).sync { self.capabilitiesResult(for: display) }
    }

    /// The same probe, run on the per-display queue **without blocking the caller**.
    ///
    /// The synchronous form above blocks whatever thread calls it: it sleeps for
    /// the DDC settle interval and then does up to three I2C reads. Its only
    /// caller is `DisplayController`, which is `@MainActor`, so the whole probe
    /// used to run on the main actor and froze the UI — with no way to show
    /// progress, because a `ProgressView` cannot draw while the thread it lives on
    /// is blocked. This variant keeps the caller responsive and hands the result
    /// back on the main actor.
    public func readCapabilities(
        for display: Display,
        completion: @escaping @MainActor (DDC.DDCCapabilities?) -> Void
    ) {
        guard isAvailable(for: display) else {
            // Deferred like the main path, so the caller always resolves on the
            // main actor and never synchronously inside the call.
            Task { @MainActor in completion(nil) }
            return
        }
        queue(for: display).async { [weak self] in
            let capabilities = self?.capabilitiesResult(for: display)
            Task { @MainActor in completion(capabilities) }
        }
    }

    /// The probe itself. **Must run on the display's queue** — both entry points
    /// above arrange that.
    private func capabilitiesResult(for display: Display) -> DDC.DDCCapabilities? {
        let key = display.identityKey
        guard !readHealth.isQuarantined(key) else {
            log.notice("readCapabilities: reads are quarantined for \(display.id) — not touching the bus")
            return nil
        }
        // The string arrives in ≤32-byte fragments, each fetched by offset; an empty
        // fragment ends it. Capped so a misbehaving display cannot loop forever.
        var assembled: [UInt8] = []
        var slowestFragment: TimeInterval = 0
        for _ in 0..<64 {
            guard queuePool.beginTransaction() else {
                log.notice("readCapabilities: DDC traffic is paused — stopping the probe for \(display.id)")
                return nil
            }
            let fragment = capabilitiesFragment(offset: UInt16(assembled.count), for: display)
            queuePool.endTransaction()
            slowestFragment = max(slowestFragment, fragment.elapsed)
            guard let payload = fragment.payload else { break }
            if payload.isEmpty { break }
            assembled.append(contentsOf: payload)
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Only accept a *complete* string: require the vcp group to be closed.
        if let text = DDC.parseCapabilitiesText(Data(assembled)),
           text.range(of: #"vcp\((?:[0-9A-Fa-f ]|\([0-9A-Fa-f ]*\))*\)"#, options: .regularExpression) != nil {
            let caps = DDC.parseCapabilities(text)
            lock.lock()
            liveCapabilitiesChecked.remove(key)
            lock.unlock()
            readHealth.recordSuccess(key)
            return caps
        }
        readHealth.recordFailure(key, elapsed: slowestFragment)
        log.warning("readCapabilities: no valid reply for \(display.id)")
        return nil
    }

    /// One capabilities fragment.
    ///
    /// - Returns: the fragment's payload (empty when the string ends) and how
    ///   long the round trip took, or a nil payload when the display did not
    ///   answer. The elapsed time is what tells a slow channel from a quiet
    ///   one: a single fragment that takes seconds is a display that is not
    ///   listening at all.
    private func capabilitiesFragment(
        offset: UInt16,
        for display: Display
    ) -> (payload: [UInt8]?, elapsed: TimeInterval) {
        let started = DispatchTime.now()
        let request = DDC.capabilitiesRequest(offset: offset)
        guard external.writeI2C(DDC.i2cAddress, data: Data(request), for: display) else {
            log.warning("readCapabilities: request write failed for \(display.id)")
            return (nil, elapsedSince(started))
        }
        Thread.sleep(forTimeInterval: Double(Settings.ddcSettleMilliseconds) / 1000)
        guard let reply = external.readI2C(DDC.i2cAddress, length: DDC.capabilitiesReplyLength, for: display),
              let fragment = DDC.parseCapabilitiesFragment(reply),
              fragment.offset == Int(offset) else {
            return (nil, elapsedSince(started))
        }
        return (fragment.payload, elapsedSince(started))
    }

    private func elapsedSince(_ started: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
    }

    /// Read capabilities, persist the VCP feature set per display identity,
    /// and update the display's DDC status.
    ///
    /// - Returns: whether the capabilities were read. A false return is not
    ///   necessarily a broken display: the probe can also be refused because a
    ///   display topology change is in progress, and the caller is expected to
    ///   try again then.
    @discardableResult
    public func autoConfigure(for display: Display) -> Bool {
        guard let caps = readCapabilities(for: display) else {
            log.warning("autoConfigure: capabilities read failed for \(display.id)")
            return false
        }
        Settings.setDDCFeatures(caps.vcpCodes, for: display.identityKey)
        display.updateDDCStatus(available: true, capabilities: caps)
        return true
    }

    /// Whether a feature is supported, from the persisted feature set
    /// (written by `autoConfigure`). Falls back to one live capabilities read
    /// per display when nothing is persisted yet.
    public func isFeatureAvailable(_ feature: DDCFeature, for display: Display) -> Bool {
        let key = display.identityKey
        let persisted = Settings.ddcFeatures(for: key)
        if !persisted.isEmpty {
            return persisted.contains(feature.vcpCode)
        }
        guard isAvailable(for: display) else { return false }

        lock.lock()
        let alreadyChecked = liveCapabilitiesChecked.contains(key)
        lock.unlock()
        guard !alreadyChecked else { return false }

        if let caps = readCapabilities(for: display) {
            Settings.setDDCFeatures(caps.vcpCodes, for: key)
            display.updateDDCStatus(available: true, capabilities: caps)
            return caps.supports(feature.vcpCode)
        }
        lock.lock()
        liveCapabilitiesChecked.insert(key)
        lock.unlock()
        return false
    }

    // MARK: - Helpers

    private func rememberMax(_ maxValue: UInt16, code: UInt8, for display: Display) {
        let key = display.identityKey
        lock.lock()
        var byCode = lastMaxValue[key] ?? [:]
        byCode[code] = maxValue
        lastMaxValue[key] = byCode
        lock.unlock()
    }

    /// Best-known maximum for a continuous feature: cached from the last
    /// successful VCP read, falling back to the MCCS standard 0…100 range.
    /// (Reading the maximum before every write would double I2C traffic and
    /// trip the write cooldown.)
    private func maxValue(for code: UInt8, display: Display) -> UInt16 {
        let key = display.identityKey
        lock.lock()
        let cached = lastMaxValue[key]?[code]
        lock.unlock()
        return cached ?? 100
    }
}
